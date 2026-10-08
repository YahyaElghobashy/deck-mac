import Foundation

public enum Transcriber {
    /// Runs whisper-cli against the wav; the audio is deleted before returning, on every path.
    public static func run(wav: URL, lang: Lang, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let base = wav.deletingPathExtension().path
            let txt = URL(fileURLWithPath: base + ".txt")
            func cleanup() { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: txt) }
            func finish(_ r: Result<String, Error>) { cleanup(); DispatchQueue.main.async { completion(r) } }
            guard let bin = DictationPaths.whisper else { return finish(.failure(VoiceError.whisperMissing)) }
            guard DictationPaths.modelExists else { return finish(.failure(VoiceError.modelMissing)) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-m", DictationPaths.model, "-f", wav.path, "-l", lang.rawValue, "-t", "8", "-otxt", "-of", base]
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = Pipe()
            do { try p.run() } catch { return finish(.failure(VoiceError.transcribeFailed(error.localizedDescription))) }
            let deadline = DispatchTime.now() + DictationLimits.transcribeTimeout
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
            if done.wait(timeout: deadline) == .timedOut { p.terminate(); return finish(.failure(VoiceError.timedOut)) }
            guard p.terminationStatus == 0 else {
                let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let line = e.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
                return finish(.failure(VoiceError.transcribeFailed(line)))
            }
            let raw = (try? String(contentsOf: txt, encoding: .utf8)) ?? ""
            let text = clean(raw)
            finish(text.isEmpty ? .failure(VoiceError.empty) : .success(text))
        }
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^)]*(BLANK_AUDIO|inaudible|silence)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
