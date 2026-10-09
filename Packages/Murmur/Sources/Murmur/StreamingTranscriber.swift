import Foundation

/// Transcribes a recording in pieces while it is still going, so that only the last few words are
/// left when the user lets go (DIC-02), and decodes every phrase in its own language (DIC-10).
///
/// Feed it the growing recording from one thread (Deck: the main thread). PauseChunker marks phrase
/// boundaries at short pauses and cuts pieces at longer ones. In AUTO each phrase is probed in the
/// background when it ends (and a long one while it is still going, so the last phrase is usually
/// judged before release). When a piece is cut, each phrase gets its language (LanguagePolicy: short
/// phrases may borrow a neighbour's, mixed ones are split into parts), runs of one language are
/// grouped, and each run is decoded with that language, in order, with the earlier text as context
/// when it was decoded the same way. `finish` does the tail and joins everything.
public final class StreamingTranscriber {
    public let lang: Lang
    private let model: String
    private var chunker = PauseChunker()
    private let work = DispatchQueue(label: "murmur.stream", qos: .userInitiated)

    static let sampleRate = Double(PauseChunker.sampleRate)
    static let minPhraseSamples = Int(LanguagePolicy.minPhraseSeconds * sampleRate)
    static let minProbeSamples = Int(LanguagePolicy.minProbeSeconds * sampleRate)
    static let reprobeEverySeconds = 2.0
    /// A probe that heard at least this share of a phrase stands for the whole phrase.
    static let probeCoverage = 0.7
    /// A tail with less speech than this is noise or a breath: whisper would invent words for it.
    static let minTailSpeechSeconds = 0.2

    // Feeding thread.
    private var lastCut = 0
    private var lastPhraseCut = 0
    private var pieces = 0
    private var nextProbeLength = StreamingTranscriber.minPhraseSamples
    private var trackedWindows = 0

    // Work queue.
    private var texts: [String] = []
    private var phraseProbes: [Int: (probe: [String: Float], covered: Int)] = [:]
    /// Sliding-window probes of mixed phrases, by phrase start and window number (see `parts`).
    private var phraseWindows: [Int: [Int: (language: String, share: Float)?]] = [:]
    private var languages: [String] = []
    private var lastLanguage: String?
    private var lastRoute: String?
    private var inferMs = 0
    private var failure: Error?

    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    /// Phrases whose probe so far sounds mixed: the feeding thread starts tracking them.
    private var _mixed: Set<Int> = []
    private func isMixedSoFar(_ start: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return _mixed.contains(start) }

    /// Timings for the metrics, delivered on the main thread: ("language_probe" | "piece", ms, detail).
    public var onEvent: ((String, Int, String?) -> Void)?

    public init(lang: Lang, model: String) {
        self.lang = lang
        self.model = model
    }

    /// A whole recording at once, the same way (Deck's fallback when streaming failed, and the
    /// test tools). Blocks the caller; throws VoiceError.empty when no speech was found.
    public static func transcribeAll(_ samples: [Float], lang: Lang, model: String) throws -> Transcript {
        let s = StreamingTranscriber(lang: lang, model: model)
        s.feed(samples)
        let job = s.finishJob(samples)
        return try s.work.sync(execute: job).get()
    }

    /// Everything recorded so far. Cheap to call often; only the new audio is examined.
    public func feed(_ samples: [Float]) {
        let found = chunker.feed(samples)
        for cut in found.phrases where cut > lastPhraseCut {
            let start = lastPhraseCut
            lastPhraseCut = cut
            nextProbeLength = Self.minPhraseSamples
            trackedWindows = 0
            if lang == .auto, cut - start >= Self.minProbeSamples {
                let phrase = Array(samples[start..<cut])
                work.async { [self] in probePhrase(phrase, start: start) }
            }
        }
        for cut in found.pieces where cut > lastCut {
            let start = lastCut
            lastCut = cut
            pieces += 1
            let bounds = [start] + chunker.phraseCuts.filter { $0 > start && $0 < cut } + [cut]
            let piece = Array(samples[start..<cut])
            work.async { [self] in transcribePiece(piece, bounds: bounds) }
        }
        // Rolling probe of the phrase still being spoken.
        let open = samples.count - lastPhraseCut
        if lang == .auto, open >= nextProbeLength {
            let start = lastPhraseCut
            let heard = Array(samples[start...])
            nextProbeLength = open + Int(Self.reprobeEverySeconds * Double(PauseChunker.sampleRate))
            work.async { [self] in probePhrase(heard, start: start) }
        }
        // A phrase that sounds mixed is tracked while it is spoken, so little is left at release.
        if lang == .auto, isMixedSoFar(lastPhraseCut) {
            let start = lastPhraseCut
            let win = Int(LanguagePolicy.trackWindowSeconds * Self.sampleRate)
            let step = Int(LanguagePolicy.trackStepSeconds * Self.sampleRate)
            while start + trackedWindows * step + win <= samples.count {
                let k = trackedWindows, a = start + k * step
                let window = Array(samples[a..<(a + win)])
                work.async { [self] in phraseWindows[start, default: [:]][k] = LanguagePolicy.strongest(runProbe(window)) }
                trackedWindows += 1
            }
        }
    }

    /// Transcribes what is left after the last cut and delivers the whole text on the main thread.
    public func finish(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
        feed(samples)
        let job = finishJob(samples)
        work.async { [self] in
            let result = job()
            DispatchQueue.main.async { if !self.cancelled { completion(result) } }
        }
    }

    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    /// Pieces handed to the transcriber so far (not counting the tail).
    public var piecesSoFar: Int { pieces }

    /// The tail after the last cut, with its phrase boundaries, measured now on the feeding thread;
    /// the returned job runs on the work queue.
    private func finishJob(_ samples: [Float]) -> () -> Result<Transcript, Error> {
        let start = lastCut, end = samples.count
        let bounds = [start] + chunker.phraseCuts.filter { $0 > start && $0 < end } + [end]
        let speech = chunker.speechSeconds(from: start, to: end)
        let tail = start < end ? Array(samples[start..<end]) : []
        let total = Double(end) / Double(PauseChunker.sampleRate)
        return { [self] in
            if speech >= Self.minTailSpeechSeconds { transcribePiece(tail, bounds: bounds) }
            if let failure { return .failure(failure) }
            // Repeats can also straddle two decoded stretches.
            let text = Transcriber.collapseLoops(texts.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(VoiceError.empty) }
            let spoken = languages.isEmpty ? (LanguagePolicy.forced(lang) ?? "auto") : languages.joined(separator: "+")
            return .success(Transcript(text: text, engine: "whisper", language: spoken, loadMs: 0, inferMs: inferMs, audioSeconds: total))
        }
    }

    // MARK: Work queue

    private func runProbe(_ samples: [Float]) -> [String: Float]? {
        guard !cancelled else { return nil }
        let started = Date()
        guard let p = try? WhisperEngine.shared.detectLanguage(samples, model: model) else { return nil }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let top3 = p.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int($0.value * 100))%" }.joined(separator: ", ")
        let detail = String(format: "%.1fs: %@", Double(samples.count) / Double(PauseChunker.sampleRate), top3)
        DispatchQueue.main.async { self.onEvent?("language_probe", ms, detail) }
        return p
    }

    /// Probes a phrase, finished or still going, unless an earlier probe already heard most of it.
    private func probePhrase(_ samples: [Float], start: Int) {
        if let known = phraseProbes[start], Double(known.covered) >= Double(samples.count) * Self.probeCoverage { return }
        guard let p = runProbe(samples) else { return }
        phraseProbes[start] = (p, samples.count)
        if LanguagePolicy.mayBeMixed(p) { lock.lock(); _mixed.insert(start); lock.unlock() }
    }

    /// `bounds` are the phrase boundaries of the piece as recording sample indices, first and last
    /// included.
    private func transcribePiece(_ samples: [Float], bounds: [Int]) {
        guard !cancelled, failure == nil, bounds.count >= 2 else { return }
        let origin = bounds[0]
        let slice = { (a: Int, b: Int) in Array(samples[(a - origin)..<(b - origin)]) }
        // Stretches of the piece with their language; nil = borrow a neighbour's.
        var units: [(a: Int, b: Int, language: String?)] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            if let forced = LanguagePolicy.forced(lang) { units.append((a, b, forced)); continue }
            guard b - a >= Self.minProbeSamples else { units.append((a, b, nil)); continue }
            let probe: [String: Float]?
            if let known = phraseProbes[a], Double(known.covered) >= Double(b - a) * Self.probeCoverage {
                probe = known.probe
            } else {
                probe = runProbe(slice(a, b)) ?? phraseProbes[a]?.probe
            }
            if b - a < Self.minPhraseSamples {
                units.append((a, b, LanguagePolicy.shortPhrase(probe)))
            } else if let top = LanguagePolicy.top(probe), Double(b - a) >= LanguagePolicy.mixedPhraseSeconds * Self.sampleRate,
                      LanguagePolicy.mayBeMixed(probe) || phraseWindows[a] != nil {
                units += parts(of: slice(a, b), at: a, phrase: top)
            } else {
                units.append((a, b, LanguagePolicy.top(probe)))
            }
        }
        for a in bounds.dropLast() { phraseProbes[a] = nil; phraseWindows[a] = nil }
        var langs = LanguagePolicy.resolve(units.map(\.language), before: lastLanguage)
        langs = LanguagePolicy.attachTerms(langs, seconds: units.map { Double($0.b - $0.a) / Self.sampleRate }, before: lastLanguage)
        if langs.contains(where: { $0 == nil }) {
            // Only short phrases so far: the piece as a whole is the best evidence there is.
            let whole = LanguagePolicy.top(runProbe(samples)) ?? "ar"
            langs = langs.map { $0 ?? whole }
        }
        var i = 0
        while i < units.count, let language = langs[i] {
            var j = i
            while j + 1 < units.count, langs[j + 1] == language { j += 1 }
            decode(slice(units[i].a, units[j].b), language: language)
            i = j + 1
        }
    }

    /// A phrase spoken in more than one language without a pause, cut where its language changes
    /// (LanguagePolicy.runs). `at` is the phrase's first sample in the recording.
    private func parts(of phrase: [Float], at start: Int, phrase top: String) -> [(a: Int, b: Int, language: String?)] {
        let win = Int(LanguagePolicy.trackWindowSeconds * Self.sampleRate)
        let step = Int(LanguagePolicy.trackStepSeconds * Self.sampleRate)
        var windows: [(language: String, share: Float)?] = []
        var t = 0
        while t + win <= phrase.count, !cancelled {
            if let tracked = phraseWindows[start]?[windows.count] {
                windows.append(tracked)
            } else {
                windows.append(LanguagePolicy.strongest(runProbe(Array(phrase[t..<(t + win)]))))
            }
            t += step
        }
        let runs = LanguagePolicy.runs(windows)
        guard runs.count > 1 else { return [(start, start + phrase.count, runs.first?.language ?? top)] }
        // Each switch lies between the middle of one run's last window and the next run's first.
        var cuts = [0]
        for (r, next) in zip(runs, runs.dropFirst()) {
            let from = r.last * step + win / 2 - step / 2, to = next.first * step + win / 2 + step / 2
            cuts.append(max(cuts.last! + 1, PauseChunker.quietest(phrase, from: from, to: to)))
        }
        cuts.append(phrase.count)
        return zip(runs, zip(cuts, cuts.dropFirst())).map { r, c in (start + c.0, start + c.1, r.language) }
    }

    private func decode(_ samples: [Float], language: String) {
        guard !cancelled, failure == nil else { return }
        // Earlier text helps only when it was decoded the same way: German decoded after Arabic and
        // English context sent whisper into its slow retry loop (2.1 s for a 3 s piece).
        let previous = language == lastRoute ? texts.joined(separator: " ") : nil
        lastRoute = language
        lastLanguage = language
        let prompt = SpeechPrompt.build(language: language, previous: previous)
        do {
            let t = try Transcriber.transcribe(samples + Self.trailingSilence, language: language, prompt: prompt)
            let text = texts.last.map { Transcriber.dropEcho(of: $0, from: t.text) } ?? t.text
            if !text.isEmpty {
                texts.append(text)
                if languages.last != language { languages.append(language) }
            }
            inferMs += t.inferMs
            let detail = String(format: "%.1fs → %@", Double(samples.count) / Double(PauseChunker.sampleRate), language)
            DispatchQueue.main.async { self.onEvent?("piece", t.inferMs, detail) }
        } catch {
            failure = error
        }
    }

    /// Appended to every decoded run: whisper tends to invent a word when audio stops abruptly.
    static let trailingSilence = [Float](repeating: 0, count: PauseChunker.sampleRate / 2)
}
