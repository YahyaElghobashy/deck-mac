import AVFoundation
import CWhisper
import Foundation

/// whisper.cpp in process. The model loads once, on the first request or ahead of time through
/// `preload`, and stays in memory until it has been idle for `idleUnload` seconds. Everything runs
/// on one serial queue, so the context is never used from two threads.
public final class WhisperEngine {
    public static let shared = WhisperEngine()

    public struct Output {
        public let text: String
        public let language: String
        public let loadMs: Int
        public let inferMs: Int
        public let audioSeconds: Double
        public let audioContext: Int
    }

    /// Seconds of idleness before the model is freed; 0 keeps it loaded until quit. Set from any
    /// thread; read only on the engine's queue.
    public var idleUnload: TimeInterval {
        get { queue.sync { _idleUnload } }
        set { queue.async { [self] in _idleUnload = newValue } }
    }
    private var _idleUnload: TimeInterval = 600

    /// Called on the engine's queue after each model load, with how long it took. Set from any thread.
    public var onLoad: ((Int) -> Void)? {
        get { queue.sync { _onLoad } }
        set { queue.async { [self] in _onLoad = newValue } }
    }
    private var _onLoad: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "murmur.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
    /// A separate state for language detection. The context's own state keeps the audio window of
    /// the last transcription, which changed the probe's answer; this one always listens the same way.
    private var probeState: OpaquePointer?
    private var loadedPath: String?
    private var unloadWork: DispatchWorkItem?

    private init() {
        whisper_log_set({ _, _, _ in }, nil)   // whisper.cpp and ggml log to stderr otherwise
    }

    public var isLoaded: Bool { queue.sync { ctx != nil } }

    /// Starts loading the model now, so the next dictation doesn't wait for it. A fresh load is
    /// followed by one second of silence through the model, which warms the GPU kernels: without
    /// it the first transcription after a load takes about 1.3 s instead of 0.8 s.
    public func preload(model: String) {
        queue.async { [self] in
            if let ms = try? ensureLoaded(model), ms > 0 { warmUp() }
            scheduleUnload()
        }
    }

    private func warmUp() {
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = 8
        p.no_timestamps = true
        p.print_progress = false
        p.print_realtime = false
        p.audio_ctx = Self.audioContext(for: 1)
        let silence = [Float](repeating: 0, count: 16_000)
        _ = "en".withCString { lang in
            p.language = lang
            return silence.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        }
    }

    public func unload() { queue.async { [self] in free() } }

    /// Frees the model before the process exits. ggml's Metal device is torn down by static
    /// destructors at exit, and a context still alive at that point trips an assertion, so every
    /// exit path must call this first.
    public func shutdown() { queue.sync { free() } }

    /// Transcribes 16 kHz mono samples. `language` is a whisper code or "auto". Blocks the caller.
    public func transcribe(_ samples: [Float], model: String, language: String, prompt: String? = nil,
                           threads: Int = 8) throws -> Output {
        try queue.sync {
            let loadMs = try ensureLoaded(model)
            defer { scheduleUnload() }
            let seconds = Double(samples.count) / 16_000
            var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            p.n_threads = Int32(threads)
            // whisper.cpp otherwise carries the previous call's text into this one as hidden
            // context: an English dictation followed by an Arabic one turned 14 s of Arabic into one
            // invented word. Context is passed explicitly, through the prompt, when wanted.
            p.no_context = true
            p.no_timestamps = true
            p.print_progress = false
            p.print_realtime = false
            p.print_special = false
            p.print_timestamps = false
            p.suppress_blank = true
            p.audio_ctx = Self.audioContext(for: seconds)
            let started = Date()
            let rc: Int32 = language.withCString { lang in
                (prompt ?? "").withCString { promptPtr in
                    p.language = lang
                    p.initial_prompt = prompt == nil ? nil : promptPtr
                    return samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
                }
            }
            guard rc == 0 else { throw VoiceError.transcribeFailed("whisper returned \(rc)") }
            var text = ""
            for i in 0..<whisper_full_n_segments(ctx) {
                if let s = whisper_full_get_segment_text(ctx, i) { text += String(cString: s) }
            }
            let lang = whisper_lang_str(whisper_full_lang_id(ctx)).map { String(cString: $0) } ?? language
            return Output(text: text, language: lang, loadMs: loadMs, inferMs: Int(Date().timeIntervalSince(started) * 1000),
                          audioSeconds: seconds, audioContext: Int(p.audio_ctx))
        }
    }

    /// Language probabilities for the start of `samples`, from whisper's own detector (one encoder
    /// pass). Keys are whisper codes; languages under 1% are left out. Blocks the caller.
    public func detectLanguage(_ samples: [Float], model: String, threads: Int = 8) throws -> [String: Float] {
        try queue.sync {
            _ = try ensureLoaded(model)
            defer { scheduleUnload() }
            if probeState == nil { probeState = whisper_init_state(ctx) }
            guard let state = probeState else { throw VoiceError.transcribeFailed("language detection could not start") }
            let melOK = samples.withUnsafeBufferPointer {
                whisper_pcm_to_mel_with_state(ctx, state, $0.baseAddress, Int32($0.count), Int32(threads))
            }
            guard melOK == 0 else { throw VoiceError.transcribeFailed("language detection could not read the audio") }
            var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
            guard whisper_lang_auto_detect_with_state(ctx, state, 0, Int32(threads), &probs) >= 0 else {
                throw VoiceError.transcribeFailed("language detection failed")
            }
            var out: [String: Float] = [:]
            for (i, p) in probs.enumerated() where p > 0.01 {
                if let code = whisper_lang_str(Int32(i)) { out[String(cString: code)] = p }
            }
            return out
        }
    }

    /// whisper encodes 50 frames per second of audio over a 1500-frame (30 s) window, and a smaller
    /// window is much faster: 0.8 s instead of 1.6 s for a 10 s clip on the M1 Pro. But the size
    /// must not vary between calls on one context: after a 768-frame call, an 832-frame call turned
    /// 14 s of Arabic into a single invented word (switching to the full window is safe both ways).
    /// So there are exactly two sizes: 768 frames for audio up to about 13 s, the full window above.
    public static func audioContext(for seconds: Double) -> Int32 {
        seconds + 2 <= 768.0 / 50 ? 768 : 0
    }

    // MARK: Model lifetime (queue only)

    /// Returns how long loading took, 0 when the model was already in memory.
    private func ensureLoaded(_ path: String) throws -> Int {
        unloadWork?.cancel(); unloadWork = nil
        if ctx != nil, loadedPath == path { return 0 }
        free()
        guard FileManager.default.fileExists(atPath: path) else { throw VoiceError.modelMissing }
        let started = Date()
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true
        guard let c = whisper_init_from_file_with_params(path, cp) else {
            throw VoiceError.transcribeFailed("the model could not be loaded")
        }
        ctx = c
        loadedPath = path
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        _onLoad?(ms)
        return ms
    }

    private func scheduleUnload() {
        unloadWork?.cancel(); unloadWork = nil
        guard _idleUnload > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.free() }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + _idleUnload, execute: work)
    }

    private func free() {
        unloadWork?.cancel(); unloadWork = nil
        if let probeState { whisper_free_state(probeState) }
        probeState = nil
        if let ctx { whisper_free(ctx) }
        ctx = nil
        loadedPath = nil
    }
}

public enum WavReader {
    /// The recorder writes 16 kHz mono 16-bit WAV; whisper wants Float samples at 16 kHz.
    public static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceError.transcribeFailed("unexpected audio format")
        }
        try file.read(into: buffer)
        guard let ch = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }
}
