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

    /// Seconds of idleness before the model is freed; 0 keeps it loaded until quit.
    public var idleUnload: TimeInterval = 600

    private let queue = DispatchQueue(label: "murmur.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
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

    /// whisper encodes 50 frames per second of audio over a 1500-frame (30 s) window and is much
    /// faster with a window sized to the dictation. 2 s of headroom, never below the 15 s window
    /// that was measured (0.8 s for a 10 s clip on the M1 Pro), and the full window from 28 s.
    public static func audioContext(for seconds: Double) -> Int32 {
        if seconds >= 28 { return 0 }
        let frames = Int(((seconds + 2) * 50 / 64).rounded(.up)) * 64
        return Int32(min(1500, max(768, frames)))
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
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    private func scheduleUnload() {
        unloadWork?.cancel(); unloadWork = nil
        guard idleUnload > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.free() }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + idleUnload, execute: work)
    }

    private func free() {
        unloadWork?.cancel(); unloadWork = nil
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
