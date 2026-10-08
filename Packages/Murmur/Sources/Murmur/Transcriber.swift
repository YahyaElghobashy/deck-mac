import Foundation

/// A finished transcription and how it was made, for the metrics.
public struct Transcript {
    public let text: String
    /// "whisper" (in process) or "whisper-cli" (the fallback).
    public let engine: String
    /// The language whisper used: the one forced, or the one it detected in AUTO.
    public let language: String
    public let loadMs: Int
    public let inferMs: Int
    public let audioSeconds: Double
}

public enum Transcriber {
    /// Transcribes the wav with the in-process engine, falling back to whisper-cli if the engine
    /// cannot run. The audio is deleted before returning, on every path. Completes on the main thread.
    /// `probe` is the language detected while recording (see LanguagePolicy); `prompt` overrides
    /// the default prompt, "" for none.
    public static func run(wav: URL, lang: Lang, probe: [String: Float]? = nil, prompt: String? = nil,
                           completion: @escaping (Result<Transcript, Error>) -> Void) {
        let decision = LanguagePolicy.decide(mode: lang, probe: probe)
        let prompt = prompt ?? SpeechPrompt.build(mixed: decision.mixedPrompt)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Transcript, Error>
            do {
                let t = try transcribe(try WavReader.samples(wav), lang: lang, probe: probe, prompt: prompt)
                result = t.text.isEmpty ? .failure(VoiceError.empty) : .success(t)
            } catch VoiceError.modelMissing {
                result = .failure(VoiceError.modelMissing)
            } catch {
                NSLog("[murmur] in-process whisper failed (%@); using whisper-cli", "\(error)")
                let started = Date()
                let seconds = (try? WavReader.samples(wav).count).map { Double($0) / 16_000 } ?? 0
                result = runCLI(wav: wav, language: decision.code, prompt: prompt).map {
                    Transcript(text: $0, engine: "whisper-cli", language: LanguagePolicy.spoken(probe: probe, decision: decision), loadMs: 0,
                               inferMs: Int(Date().timeIntervalSince(started) * 1000), audioSeconds: seconds)
                }
            }
            try? FileManager.default.removeItem(at: wav)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Deck's in-process path on samples already in memory: the engine, the clean-up, and the
    /// prompt-echo guard. Blocks the caller. An empty `text` means no speech was found.
    public static func transcribe(_ samples: [Float], lang: Lang, probe: [String: Float]? = nil, complete: Bool = true,
                                  prompt: String? = nil) throws -> Transcript {
        guard DictationPaths.modelExists else { throw VoiceError.modelMissing }
        let decision = LanguagePolicy.decide(mode: lang, probe: probe, complete: complete)
        let prompt = prompt ?? SpeechPrompt.build(mixed: decision.mixedPrompt)
        let out = try WhisperEngine.shared.transcribe(samples, model: DictationPaths.model, language: decision.code,
                                                      prompt: prompt.isEmpty ? nil : prompt)
        var text = clean(out.text)
        if SpeechPrompt.isEcho(text, of: prompt) { text = "" }
        if decision.englishOnlyEvidence { text = dropStrayArabicLead(text) }
        return Transcript(text: text, engine: "whisper", language: LanguagePolicy.spoken(probe: probe, decision: decision), loadMs: out.loadMs,
                          inferMs: out.inferMs, audioSeconds: out.audioSeconds)
    }

    /// The fallback: one whisper-cli process per dictation, which reloads the model every time.
    static func runCLI(wav: URL, language: String, prompt: String) -> Result<String, Error> {
        let base = wav.deletingPathExtension().path
        let txt = URL(fileURLWithPath: base + ".txt")
        defer { try? FileManager.default.removeItem(at: txt) }
        guard let bin = DictationPaths.whisper else { return .failure(VoiceError.whisperMissing) }
        guard DictationPaths.modelExists else { return .failure(VoiceError.modelMissing) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", DictationPaths.model, "-f", wav.path, "-l", language, "-t", "8", "-otxt", "-of", base]
            + (prompt.isEmpty ? [] : ["--prompt", prompt])
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

    /// "درست: Draft a follow-up email…" → "Draft a follow-up email…": the Arabic token sometimes writes
    /// the first English word in Arabic script. Only one or two leading Arabic-script words go, and
    /// only when everything after them is Latin script, so genuinely mixed text is never touched.
    public static func dropStrayArabicLead(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let isArabic: (Substring) -> Bool = { $0.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }
        let lead = words.prefix { isArabic($0) }.count
        guard (1...2).contains(lead), words.count > lead, !words.dropFirst(lead).contains(where: isArabic) else { return text }
        return words.dropFirst(lead).joined(separator: " ")
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^)]*(BLANK_AUDIO|inaudible|silence)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
