import Foundation

/// Transcribes a recording in pieces while it is still going, so that only the last few words are
/// left when the user lets go (DIC-02).
///
/// Feed it the growing recording from the main thread. PauseChunker cuts at pauses; each piece is
/// transcribed in order, in the background, with the text so far as context. In AUTO the language
/// is probed about two seconds in (for the first piece) and again on every later piece, so a change
/// of language at a pause is followed (DIC-10). `finish` transcribes the tail and joins everything.
public final class StreamingTranscriber {
    public let lang: Lang
    private let model: String
    private var chunker = PauseChunker()
    private let work = DispatchQueue(label: "murmur.stream", qos: .userInitiated)

    // Main thread.
    private var lastCut = 0
    private var pieces = 0
    private var probed = false

    // Work queue.
    private var texts: [String] = []
    private var probe: [String: Float]?
    private var inferMs = 0
    private var failure: Error?

    /// Appended to every piece: whisper tends to invent a word when audio stops abruptly.
    static let trailingSilence = [Float](repeating: 0, count: PauseChunker.sampleRate / 2)

    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    /// Timings for the metrics, delivered on the main thread: ("language_probe" | "piece", ms, detail).
    public var onEvent: ((String, Int, String?) -> Void)?

    public init(lang: Lang, model: String) {
        self.lang = lang
        self.model = model
    }

    /// Everything recorded so far. Cheap to call often; only the new audio is examined.
    public func feed(_ samples: [Float]) {
        let probeLength = Int(LanguagePolicy.probeSeconds * Double(PauseChunker.sampleRate))
        if lang == .auto, !probed, samples.count >= probeLength {
            probed = true
            let head = Array(samples.prefix(probeLength))
            work.async { [self] in runProbe(head) }
        }
        for cut in chunker.feed(samples) where cut > lastCut {
            let piece = Array(samples[lastCut..<cut])
            lastCut = cut
            let reprobe = pieces > 0
            pieces += 1
            work.async { [self] in
                if reprobe { runProbe(piece) }
                transcribePiece(piece)
            }
        }
    }

    /// Transcribes what is left after the last cut and delivers the whole text on the main thread.
    public func finish(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
        let tail = lastCut < samples.count ? Array(samples[lastCut...]) : []
        let total = Double(samples.count) / Double(PauseChunker.sampleRate)
        work.async { [self] in
            if tail.count >= PauseChunker.sampleRate / 4 { transcribePiece(tail) }
            let result: Result<Transcript, Error>
            if let failure {
                result = .failure(failure)
            } else {
                let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let decision = LanguagePolicy.decide(mode: lang, probe: probe)
                result = text.isEmpty ? .failure(VoiceError.empty)
                    : .success(Transcript(text: text, engine: "whisper", language: LanguagePolicy.spoken(probe: probe, decision: decision),
                                          loadMs: 0, inferMs: inferMs, audioSeconds: total))
            }
            DispatchQueue.main.async { if !self.cancelled { completion(result) } }
        }
    }

    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    /// Pieces handed to the transcriber so far (not counting the tail).
    public var piecesSoFar: Int { pieces }

    // MARK: Work queue

    private func runProbe(_ samples: [Float]) {
        guard !cancelled else { return }
        let started = Date()
        guard let p = try? WhisperEngine.shared.detectLanguage(samples, model: model) else { return }
        probe = p
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let top = p.max { $0.value < $1.value }.map { "\($0.key) \(Int($0.value * 100))%" }
        DispatchQueue.main.async { self.onEvent?("language_probe", ms, top) }
    }

    private func transcribePiece(_ samples: [Float]) {
        guard !cancelled, failure == nil else { return }
        let decision = LanguagePolicy.decide(mode: lang, probe: probe)
        let prompt = SpeechPrompt.build(mixed: decision.mixedPrompt, previous: texts.joined(separator: " "))
        do {
            let t = try Transcriber.transcribe(samples + Self.trailingSilence, lang: lang, probe: probe, prompt: prompt)
            if !t.text.isEmpty { texts.append(t.text) }
            inferMs += t.inferMs
            let seconds = String(format: "%.1fs %@", t.audioSeconds, decision.code)
            DispatchQueue.main.async { self.onEvent?("piece", t.inferMs, seconds) }
        } catch {
            failure = error
        }
    }
}
