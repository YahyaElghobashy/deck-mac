import AVFoundation
import Foundation

public enum VoiceError: LocalizedError {
    case micDenied, noInput, engineFailed(String), tooShort, silent, whisperMissing, modelMissing, transcribeFailed(String), timedOut, empty

    public var errorDescription: String? {
        switch self {
        case .micDenied: return "Microphone access is off"
        case .noInput: return "No microphone found"
        case .engineFailed(let m): return "Audio engine failed: \(m)"
        case .tooShort: return "Too short, ignored"
        case .silent: return "Nothing heard"
        case .whisperMissing: return "whisper-cli not found"
        case .modelMissing: return "Whisper model not found"
        case .transcribeFailed(let m): return "Transcription failed: \(m)"
        case .timedOut: return "Transcription timed out"
        case .empty: return "No speech detected"
        }
    }
}

/// Captures the default input straight to a 16 kHz mono WAV — exactly what whisper wants.
public final class Recorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var url: URL?
    private var startedAt: Date?
    private var peak: Float = 0
    private let lock = NSLock()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    public var onLevel: ((Float) -> Void)?

    private let diskSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]

    public init() {}

    public var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return (pausedAt ?? Date()).timeIntervalSince(startedAt) - pausedTotal
    }
    public var isPaused: Bool { pausedAt != nil }
    public var sawSound: Bool { lock.lock(); defer { lock.unlock() }; return peak > DictationLimits.silenceRMSFloor }

    public func pause() {
        guard engine.isRunning, pausedAt == nil else { return }
        engine.pause()
        pausedAt = Date()
    }

    public func resume() {
        guard let at = pausedAt else { return }
        pausedTotal += Date().timeIntervalSince(at)
        pausedAt = nil
        try? engine.start()
    }

    public func start() throws {
        lock.lock(); peak = 0; lock.unlock()
        pausedAt = nil; pausedTotal = 0
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw VoiceError.noInput }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("clip-\(UUID().uuidString).wav")
        url = out
        let f = try AVAudioFile(forWriting: out, settings: diskSettings)
        guard let conv = AVAudioConverter(from: hw, to: f.processingFormat) else {
            throw VoiceError.engineFailed("cannot convert \(Int(hw.sampleRate))Hz to 16kHz")
        }
        lock.lock(); file = f; converter = conv; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in self?.consume(buf) }
        engine.prepare()
        do { try engine.start() } catch { throw VoiceError.engineFailed(error.localizedDescription) }
        startedAt = Date()
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        if let ch = buf.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(buf.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            lock.lock(); if rms > peak { peak = rms }; lock.unlock()
            let shaped = min(1, pow(max(0, rms) * 16, 0.72))
            DispatchQueue.main.async { self.onLevel?(shaped) }
        }
        lock.lock(); defer { lock.unlock() }
        guard let conv = converter, let file else { return }
        let target = file.processingFormat
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var supplied = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0 else { return }
        do { try file.write(from: out) } catch { NSLog("[deck] write failed: %@", "\(error)") }
    }

    @discardableResult
    public func stop() -> (url: URL?, seconds: TimeInterval) {
        let secs = duration
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock(); file = nil; converter = nil; lock.unlock()
        startedAt = nil
        let u = url
        url = nil
        return (u, secs)
    }

    public func discard() {
        let (u, _) = stop()
        if let u { try? FileManager.default.removeItem(at: u) }
    }

    public static func requestMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }
}
