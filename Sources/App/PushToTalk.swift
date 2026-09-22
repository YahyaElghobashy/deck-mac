import AVFoundation
import Foundation
import Speech

/// Press → listen → stop on silence → text → Echo → Alexa's reply text.
@MainActor
final class PushToTalk: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, transcribing, sending, waiting, done, failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var level: Float = 0
    @Published var exchange: AlexaExchange? = nil
    @Published var engineUsed = "apple"

    var onPhaseChange: ((Phase) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var monitor: Timer?
    private var startedAt = Date()
    private var lastChange = Date()
    private var heardSpeech = false
    private var silenceSince: Date? = nil
    private var samples: [Float] = []        // whisper mode: mono at input rate
    private var inputRate: Double = 48_000
    private var useWhisper = false
    private var settings = DeckSettings.load()

    var isActive: Bool { phase == .listening || phase == .transcribing || phase == .sending || phase == .waiting }

    func toggle() {
        if phase == .listening { finishListening() } else if !isActive { start() }
    }

    func start() {
        settings = DeckSettings.load()
        transcript = ""
        exchange = nil
        samples = []
        heardSpeech = false
        silenceSince = nil
        set(.listening)
        Task { await prepareAndCapture() }
    }

    private func set(_ p: Phase) {
        phase = p
        onPhaseChange?(p)
    }

    private func prepareAndCapture() async {
        let micOK = await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
        guard micOK else { set(.failed("Microphone access denied — System Settings → Privacy → Microphone → Deck")); return }

        useWhisper = settings.speechEngine == "whisper"
        if !useWhisper {
            let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            let rec = SFSpeechRecognizer(locale: Locale(identifier: settings.speechLocale))
            if auth != .authorized || rec == nil || rec?.isAvailable == false {
                DebugLog.write("apple speech unavailable (\(auth.rawValue)); whisper fallback")
                useWhisper = true
            } else {
                recognizer = rec
            }
        }
        engineUsed = useWhisper ? "whisper" : "apple"
        do { try beginCapture() } catch { set(.failed("Audio engine: \(error.localizedDescription)")) }
    }

    private func beginCapture() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        inputRate = fmt.sampleRate

        if !useWhisper, let recognizer {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.taskHint = .dictation
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in self?.handle(result: result, error: error) }
            }
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            // level + silence tracking (mono mix of channel 0)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            let mono = Array(UnsafeBufferPointer(start: ch, count: n))
            Task { @MainActor in
                self.level = min(1, rms * 8)
                if self.useWhisper { self.samples.append(contentsOf: mono) }
                self.track(rms: rms)
            }
        }
        engine.prepare()
        try engine.start()
        startedAt = Date()
        lastChange = Date()
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEndpoint() }
        }
    }

    private func track(rms: Float) {
        let speaking = rms > 0.012
        if speaking {
            heardSpeech = true
            silenceSince = nil
        } else if heardSpeech, silenceSince == nil {
            silenceSince = Date()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if text != transcript {
                transcript = text
                lastChange = Date()
                heardSpeech = true
            }
        }
        if let error, phase == .listening {
            DebugLog.write("speech error: \(error.localizedDescription)")
        }
    }

    private func checkEndpoint() {
        guard phase == .listening else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > settings.maxListenSeconds { finishListening(); return }
        if useWhisper {
            if heardSpeech, let s = silenceSince, Date().timeIntervalSince(s) > settings.silenceSeconds + 0.3 { finishListening(); return }
            if !heardSpeech, elapsed > 6 { cancel("Didn't hear anything"); return }
        } else {
            if !transcript.isEmpty, Date().timeIntervalSince(lastChange) > settings.silenceSeconds { finishListening(); return }
            if transcript.isEmpty, elapsed > 6 { cancel("Didn't hear anything"); return }
        }
    }

    private func stopAudio() {
        monitor?.invalidate()
        monitor = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
    }

    func cancel(_ reason: String = "Cancelled") {
        stopAudio()
        set(.failed(reason))
    }

    func finishListening() {
        guard phase == .listening else { return }
        stopAudio()
        if useWhisper {
            set(.transcribing)
            let captured = samples
            let rate = inputRate
            let model = (settings.whisperModelPath as NSString).expandingTildeInPath
            Task.detached { [weak self] in
                let text = WhisperRunner.transcribe(samples: captured, rate: rate, modelPath: model)
                await MainActor.run {
                    guard let self else { return }
                    self.transcript = text
                    self.send()
                }
            }
        } else {
            send()
        }
    }

    private func send() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { set(.failed("Nothing to send")); return }
        set(.sending)
        Task {
            do {
                let at = try await BridgeClient.sendText(text)
                set(.waiting)
                exchange = AlexaExchange(utterance: text, response: nil, at: at, device: nil, note: nil)
                let deadline = Date().addingTimeInterval(16)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    let r = try await BridgeClient.reply(after: at - 1000)
                    if let ex = r.exchange, ex.response != nil || !r.pending {
                        exchange = ex
                        set(.done)
                        return
                    }
                }
                exchange = AlexaExchange(utterance: text, response: nil, at: at, device: nil, note: "Sent — Alexa answered on the Echo, no text came back")
                set(.done)
            } catch {
                set(.failed(error.localizedDescription))
            }
        }
    }
}

/// Runs whisper.cpp on a captured buffer (16 kHz mono WAV in a temp file).
enum WhisperRunner {
    static func transcribe(samples: [Float], rate: Double, modelPath: String) -> String {
        guard !samples.isEmpty else { return "" }
        // resample to 16k by simple linear interpolation (speech, short clips)
        let ratio = rate / 16_000
        let outCount = Int(Double(samples.count) / ratio)
        var pcm = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = samples[min(idx, samples.count - 1)]
            let b = samples[min(idx + 1, samples.count - 1)]
            let v = a + (b - a) * frac
            pcm[i] = Int16(max(-1, min(1, v)) * 32767)
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-ptt-\(UUID().uuidString)")
        let wav = tmp.appendingPathExtension("wav")
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: tmp.appendingPathExtension("txt")) }

        guard let bin = DictationPaths.whisper else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", modelPath, "-f", wav.path, "-l", "auto", "-t", "8", "-nt", "-otxt", "-of", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return "" }
        let txt = (try? String(contentsOf: tmp.appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        return txt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
