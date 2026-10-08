import Foundation

public enum Transcriber {
    /// Which engine produced the last transcript: "whisper" (in process) or "whisper-cli".
    /// Set on the main thread just before the completion runs.
    public private(set) static var lastEngine = "whisper"

    /// Transcribes the wav with the in-process engine, falling back to whisper-cli if the engine
    /// cannot run. The audio is deleted before returning, on every path.
    public static func run(wav: URL, lang: Lang, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            var engine = "whisper"
            do {
                guard DictationPaths.modelExists else { throw VoiceError.modelMissing }
                let samples = try WavReader.samples(wav)
                let out = try WhisperEngine.shared.transcribe(samples, model: DictationPaths.model, language: lang.rawValue)
                let text = clean(out.text)
                result = text.isEmpty ? .failure(VoiceError.empty) : .success(text)
            } catch VoiceError.modelMissing {
                result = .failure(VoiceError.modelMissing)
            } catch {
                NSLog("[murmur] in-process whisper failed (%@); using whisper-cli", "\(error)")
                engine = "whisper-cli"
                result = runCLI(wav: wav, lang: lang)
            }
            try? FileManager.default.removeItem(at: wav)
            DispatchQueue.main.async { lastEngine = engine; completion(result) }
        }
    }

    /// The fallback: one whisper-cli process per dictation, which reloads the model every time.
    static func runCLI(wav: URL, lang: Lang) -> Result<String, Error> {
        let base = wav.deletingPathExtension().path
        let txt = URL(fileURLWithPath: base + ".txt")
        defer { try? FileManager.default.removeItem(at: txt) }
        guard let bin = DictationPaths.whisper else { return .failure(VoiceError.whisperMissing) }
        guard DictationPaths.modelExists else { return .failure(VoiceError.modelMissing) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", DictationPaths.model, "-f", wav.path, "-l", lang.rawValue, "-t", "8", "-otxt", "-of", base]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch { return .failure(VoiceError.transcribeFailed(error.localizedDescription)) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + DictationLimits.transcribeTimeout) == .timedOut { p.terminate(); return .failure(VoiceError.timedOut) }
        guard p.terminationStatus == 0 else {
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let line = e.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
            return .failure(VoiceError.transcribeFailed(line))
        }
        let text = clean((try? String(contentsOf: txt, encoding: .utf8)) ?? "")
        return text.isEmpty ? .failure(VoiceError.empty) : .success(text)
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^)]*(BLANK_AUDIO|inaudible|silence)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
