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
    /// Transcribes the wav with the in-process engine, phrase by phrase in AUTO (see
    /// StreamingTranscriber), falling back to whisper-cli if the engine cannot run. The audio is
    /// deleted before returning, on every path. Completes on the main thread.
    public static func run(wav: URL, lang: Lang, completion: @escaping (Result<Transcript, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Transcript, Error>
            do {
                result = .success(try StreamingTranscriber.transcribeAll(try WavReader.samples(wav), lang: lang, model: DictationPaths.model))
            } catch VoiceError.modelMissing {
                result = .failure(VoiceError.modelMissing)
            } catch VoiceError.empty {
                result = .failure(VoiceError.empty)
            } catch {
                NSLog("[murmur] in-process whisper failed (%@); using whisper-cli", "\(error)")
                // whisper-cli decodes the whole file in one language; in AUTO it picks that itself.
                let language = LanguagePolicy.forced(lang) ?? "auto"
                let started = Date()
                let seconds = (try? WavReader.samples(wav).count).map { Double($0) / 16_000 } ?? 0
                result = runCLI(wav: wav, language: language, prompt: SpeechPrompt.build(lang: lang)).map {
                    Transcript(text: $0, engine: "whisper-cli", language: language, loadMs: 0,
                               inferMs: Int(Date().timeIntervalSince(started) * 1000), audioSeconds: seconds)
                }
            }
            try? FileManager.default.removeItem(at: wav)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// One stretch of audio decoded in one language with the in-process engine: the clean-up and
    /// the prompt-echo guard included. Blocks the caller. An empty `text` means no speech was found.
    public static func transcribe(_ samples: [Float], language: String, prompt: String) throws -> Transcript {
        guard DictationPaths.modelExists else { throw VoiceError.modelMissing }
        let out = try WhisperEngine.shared.transcribe(samples, model: DictationPaths.model, language: language,
                                                      prompt: prompt.isEmpty ? nil : prompt)
        var text = clean(out.text)
        if SpeechPrompt.isEcho(text, of: prompt) { text = "" }
        return Transcript(text: text, engine: "whisper", language: language, loadMs: out.loadMs,
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

    /// Subtitle credits whisper learned from video captions and writes after speech ends, mostly on
    /// Arabic and German. Nobody dictates these, so they are removed wherever they appear.
    static let inventedCredits = [
        "ترجمة نانسي قنقر", "نانسي قنقر", "اشتركوا في القناة", "اشترك في القناة",
        "Untertitel im Auftrag des ZDF für funk, 2017", "Untertitel im Auftrag des ZDF", "Untertitel der Amara.org-Community",
        "Subtitles by the Amara.org community",
    ]

    /// whisper repeating itself, not speech: one copy stays. Two kinds: a phrase of six or more
    /// characters three or more times in a row (looping on audio it can't read), and a stretch of
    /// three or more words twice in a row (large-v3 often writes a sentence twice, 9 Oct 2026). A
    /// sentence the speaker really says twice running is rare enough to lose.
    public static func collapseLoops(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?<!\S)(\S.{5,}?)(?:[\s,.،"]*\1){2,}"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<!\S)(\S+(?:\s+\S+){2,}?)(?:[\s,.،؟?!"]*\1)+(?!\S)"#, with: "$1", options: .regularExpression)
        return t
    }

    /// A stretch that starts by repeating the end of the text before it (whisper copying the context
    /// it was given): the repeat goes. Compares the previous text whole, then its last sentence of
    /// three or more words.
    public static func dropEcho(of previous: String, from text: String) -> String {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let t = trim(text)
        var candidates = [trim(previous)]
        let sentences = previous.split(whereSeparator: { ".!?؟".contains($0) }).map { trim(String($0)) }.filter { !$0.isEmpty }
        if let last = sentences.last, last.split(separator: " ").count >= 3 { candidates.append(last) }
        for c in candidates where !c.isEmpty && t.hasPrefix(c) {
            return trim(String(t.dropFirst(c.count).drop { ".,،!?؟ ".contains($0) }))
        }
        return t
    }

    public static func clean(_ s: String) -> String {
        var t = s
        for credit in inventedCredits { t = t.replacingOccurrences(of: credit, with: "", options: .caseInsensitive) }
        t = collapseLoops(t)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^)]*(BLANK_AUDIO|inaudible|silence)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
