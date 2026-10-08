import Foundation

/// Transcribes a recording in pieces while it is still going, so that only the last few words are
/// left when the user lets go (DIC-02), and gives every piece its own language (DIC-10).
///
/// Feed it the growing recording from the main thread. PauseChunker cuts at pauses (pieces of at
/// least 2 s), so a change of language at a pause starts a new piece. In AUTO the open piece is
/// probed when it reaches 1.2 s and every 3 s after that, in the background (so even a short last
/// phrase is usually judged before release); a finished piece uses
/// that probe if it heard most of it, otherwise it is probed whole. Pieces are transcribed in
/// order, with the text so far as context. `finish` does the tail and joins everything.
public final class StreamingTranscriber {
    public let lang: Lang
    private let model: String
    private var chunker = PauseChunker()
    private let work = DispatchQueue(label: "murmur.stream", qos: .userInitiated)

    static let firstProbeSeconds = 1.2
    static let reprobeEverySeconds = 3.0
    /// A probe that heard at least this share of a piece stands for the whole piece.
    static let probeCoverage = 0.4

    // Main thread.
    private var lastCut = 0
    private var pieces = 0
    private var nextProbeLength = 0

    // Work queue.
    private var texts: [String] = []
    private var segmentProbes: [Int: (probe: [String: Float], covered: Int)] = [:]
    private var lastProbe: [String: Float]?
    private var languages: [String] = []
    private var lastRoute: String?
    private var inferMs = 0
    private var failure: Error?

    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    /// Timings for the metrics, delivered on the main thread: ("language_probe" | "piece", ms, detail).
    public var onEvent: ((String, Int, String?) -> Void)?

    public init(lang: Lang, model: String) {
        self.lang = lang
        self.model = model
        nextProbeLength = Int(Self.firstProbeSeconds * Double(PauseChunker.sampleRate))
    }

    /// Everything recorded so far. Cheap to call often; only the new audio is examined.
    public func feed(_ samples: [Float]) {
        for cut in chunker.feed(samples) where cut > lastCut {
            let start = lastCut
            let piece = Array(samples[start..<cut])
            lastCut = cut
            pieces += 1
            nextProbeLength = Int(Self.firstProbeSeconds * Double(PauseChunker.sampleRate))
            work.async { [self] in transcribePiece(piece, segment: start) }
        }
        // Rolling probe of the piece still being spoken.
        let open = samples.count - lastCut
        if lang == .auto, open >= nextProbeLength {
            let start = lastCut
            let heard = Array(samples[start..<samples.count])
            nextProbeLength = open + Int(Self.reprobeEverySeconds * Double(PauseChunker.sampleRate))
            work.async { [self] in
                if let p = runProbe(heard) {
                    segmentProbes[start] = (LanguagePolicy.merge(segmentProbes[start]?.probe, p), heard.count)
                }
            }
        }
    }

    /// Transcribes what is left after the last cut and delivers the whole text on the main thread.
    public func finish(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
        let start = lastCut
        let tail = start < samples.count ? Array(samples[start...]) : []
        let total = Double(samples.count) / Double(PauseChunker.sampleRate)
        work.async { [self] in
            if tail.count >= PauseChunker.sampleRate / 4 { transcribePiece(tail, segment: start) }
            let result: Result<Transcript, Error>
            if let failure {
                result = .failure(failure)
            } else {
                let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let spoken = languages.isEmpty ? LanguagePolicy.decide(mode: lang, probe: nil).code : languages.joined(separator: "+")
                result = text.isEmpty ? .failure(VoiceError.empty)
                    : .success(Transcript(text: text, engine: "whisper", language: spoken, loadMs: 0, inferMs: inferMs, audioSeconds: total))
            }
            DispatchQueue.main.async { if !self.cancelled { completion(result) } }
        }
    }

    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    /// Pieces handed to the transcriber so far (not counting the tail).
    public var piecesSoFar: Int { pieces }

    // MARK: Work queue

    @discardableResult
    private func runProbe(_ samples: [Float]) -> [String: Float]? {
        guard !cancelled else { return nil }
        let started = Date()
        guard let p = try? WhisperEngine.shared.detectLanguage(samples, model: model) else { return nil }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let top3 = p.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int($0.value * 100))%" }.joined(separator: ", ")
        DispatchQueue.main.async { self.onEvent?("language_probe", ms, top3) }
        return p
    }

    /// The language evidence for a piece: the rolling probe if it heard most of it, a fresh probe
    /// of the whole piece otherwise (very short pieces reuse the previous piece's).
    /// Also says whether the evidence covers (nearly) the whole piece: only then may it pick the
    /// English token (LanguagePolicy).
    private func probe(for piece: [Float], segment: Int) -> (probe: [String: Float]?, complete: Bool) {
        guard lang == .auto else { return (nil, true) }
        if let rolling = segmentProbes[segment], Double(rolling.covered) >= Double(piece.count) * Self.probeCoverage {
            return (rolling.probe, Double(rolling.covered) >= Double(piece.count) * 0.9)
        }
        if piece.count >= PauseChunker.sampleRate, let fresh = runProbe(piece) {
            return (LanguagePolicy.merge(segmentProbes[segment]?.probe, fresh), true)
        }
        return (segmentProbes[segment]?.probe ?? lastProbe, false)
    }

    private func transcribePiece(_ samples: [Float], segment: Int) {
        guard !cancelled, failure == nil else { return }
        let (probe, complete) = probe(for: samples, segment: segment)
        segmentProbes[segment] = nil
        if probe != nil { lastProbe = probe }
        let decision = LanguagePolicy.decide(mode: lang, probe: probe, complete: complete)
        // Earlier text helps only when it was decoded the same way: German decoded after Arabic and
        // English context sent whisper into its slow retry loop (2.1 s for a 3 s piece).
        let previous = decision.code == lastRoute ? texts.joined(separator: " ") : nil
        lastRoute = decision.code
        let prompt = SpeechPrompt.build(mixed: decision.mixedPrompt, previous: previous)
        do {
            let t = try Transcriber.transcribe(samples + Self.trailingSilence, lang: lang, probe: probe, complete: complete, prompt: prompt)
            if !t.text.isEmpty {
                texts.append(t.text)
                if languages.last != t.language { languages.append(t.language) }
            }
            inferMs += t.inferMs
            let detail = String(format: "%.1fs → %@", Double(samples.count) / Double(PauseChunker.sampleRate), decision.code)
            DispatchQueue.main.async { self.onEvent?("piece", t.inferMs, detail) }
        } catch {
            failure = error
        }
    }

    /// Appended to every piece: whisper tends to invent a word when audio stops abruptly.
    static let trailingSilence = [Float](repeating: 0, count: PauseChunker.sampleRate / 2)
}
