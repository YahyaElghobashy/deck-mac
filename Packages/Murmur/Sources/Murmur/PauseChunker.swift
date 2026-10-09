import Foundation

/// Finds the places to cut a growing recording. Pure logic over 16 kHz samples: it looks at 30 ms
/// frames, tracks the noise floor, and cuts in a pause, never inside a word. Two kinds of cut:
///
/// - Phrase boundaries, at every short pause (0.2 s): people switch language between phrases, so
///   each phrase gets its own language (LanguagePolicy).
/// - Piece cuts, at longer pauses (0.4 s) once a piece has 2 s of audio: each piece is transcribed
///   while the user is still talking. Every piece cut is also a phrase boundary.
public struct PauseChunker {
    public static let sampleRate = 16_000
    static let frame = 480                        // 30 ms

    /// A piece needs at least this much audio before a pause may end it.
    public var minChunkSeconds: Double = 2.0
    /// Silence at least this long ends a piece.
    public var minPauseSeconds: Double = 0.4
    /// Silence at least this long ends a phrase.
    public var minPhrasePauseSeconds: Double = 0.2
    /// A piece this long ends at the next phrase boundary even without a long pause, so a long
    /// stretch of speech with only brief pauses isn't all left for the release. Not shorter: each
    /// piece is decoded on its own, and cutting at every brief pause after 3 s split Arabic words
    /// in two ("نجد. دده") and doubled the mixed error rate.
    public var phrasePieceSeconds: Double = 6.0
    /// Past this, the piece is cut at its quietest point even without a pause.
    public var maxChunkSeconds: Double = 25.0

    private var levels: [Float] = []              // RMS per frame, for the whole recording so far
    private var lastCut = 0                        // sample index of the last piece cut
    private var lastPhraseCut = 0
    public private(set) var cuts: [Int] = []
    public private(set) var phraseCuts: [Int] = []

    public init() {}

    /// What one `feed` found: new piece cuts and new phrase boundaries, as sample indices.
    public struct Found {
        public var pieces: [Int] = []
        public var phrases: [Int] = []
    }

    /// Feeds the whole recording so far (it reads only what is new) and returns the new cut points.
    public mutating func feed(_ samples: [Float]) -> Found {
        var found = Found()
        let frames = samples.count / Self.frame
        while levels.count < frames {
            let start = levels.count * Self.frame
            var sum: Float = 0
            for i in start..<(start + Self.frame) { sum += samples[i] * samples[i] }
            levels.append((sum / Float(Self.frame)).squareRoot())
            if let p = phrasePoint() {
                phraseCuts.append(p); found.phrases.append(p); lastPhraseCut = p
                if p - lastCut >= Int(phrasePieceSeconds * Double(Self.sampleRate)) {
                    cuts.append(p); found.pieces.append(p); lastCut = p
                }
            }
            if let cut = cutPoint() {
                cuts.append(cut); found.pieces.append(cut); lastCut = cut
                if lastPhraseCut != cut {               // a piece always ends a phrase
                    phraseCuts.append(cut); found.phrases.append(cut); lastPhraseCut = cut
                }
            }
        }
        return found
    }

    /// Seconds of speech between two sample indices, by the current threshold. Silence and noise
    /// alone make whisper invent words, so tiny tails are dropped by this measure.
    public func speechSeconds(from: Int, to: Int) -> Double {
        let a = max(0, from / Self.frame), b = min(levels.count, to / Self.frame)
        guard b > a else { return 0 }
        let th = threshold(upTo: levels.count)
        return Double(levels[a..<b].filter { $0 >= th }.count * Self.frame) / Double(Self.sampleRate)
    }

    /// The gap between two words, between two sample indices: the quietest 10 ms inside the
    /// quietest 100 ms. 100 ms first, so the brief silence inside a consonant ("dic|tation") loses
    /// to a real gap.
    public static func quietest(_ samples: [Float], from: Int, to: Int) -> Int {
        let hop = 160, span = 10                        // 10 ms steps, 100 ms window
        let lo = max(0, from), hi = min(samples.count, to)
        let n = (hi - lo) / hop
        guard n > span else { return (lo + hi) / 2 }
        var energy = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            for j in (lo + i * hop)..<(lo + (i + 1) * hop) { sum += samples[j] * samples[j] }
            energy[i] = sum
        }
        var window = energy[0..<span].reduce(0, +)
        var best = 0, bestEnergy = window
        for i in 1...(n - span) {
            window += energy[i + span - 1] - energy[i - 1]
            if window < bestEnergy { bestEnergy = window; best = i }
        }
        let inner = (best..<(best + span)).min { energy[$0] < energy[$1] }!
        return lo + inner * hop + hop / 2
    }

    /// Speech threshold: well above the noise floor (the quiet 10th percentile of the last ten
    /// seconds), and never below an absolute floor so a silent room isn't read as speech.
    private func threshold(upTo end: Int) -> Float {
        let window = levels[max(0, end - 333)..<end].sorted()
        let floor = window.isEmpty ? 0 : window[window.count / 10]
        return max(floor * 3.0, 0.006)
    }

    private func frames(_ seconds: Double) -> Int { Int(seconds * Double(Self.sampleRate) / Double(Self.frame)) }

    /// The cut for a pause that has lasted `pauseFrames` up to now: 0.15 s after the speech stopped.
    /// Cutting in the middle of the pause left a soft word onset at the end of a piece, which
    /// whisper turned into an extra word ("زيادة عميلة" for "زيادة … عشان"). Phrase and piece cuts
    /// for the same pause land on the same sample.
    private func cutAfterSpeech(pauseFrames: Int) -> Int { (levels.count - pauseFrames + 5) * Self.frame }

    private func phrasePoint() -> Int? {
        let pause = frames(minPhrasePauseSeconds)
        let th = threshold(upTo: levels.count)
        guard levels.count > pause, levels.suffix(pause).allSatisfy({ $0 < th }) else { return nil }
        // At least 0.3 s of speech since the last boundary: one boundary per pause, none in silence.
        let from = lastPhraseCut / Self.frame, to = levels.count - pause
        guard to > from, levels[from..<to].filter({ $0 >= th }).count >= frames(0.3) else { return nil }
        let cut = cutAfterSpeech(pauseFrames: pause)
        return cut > lastPhraseCut ? cut : nil
    }

    private func cutPoint() -> Int? {
        let fr = Self.frame
        let start = lastCut / fr
        let chunkFrames = levels.count - start
        let pauseFrames = frames(minPauseSeconds)
        guard chunkFrames >= frames(minChunkSeconds) else { return nil }

        let th = threshold(upTo: levels.count)
        // Silence alone never becomes a chunk: whisper invents words for silent audio.
        guard levels[start..<levels.count].filter({ $0 >= th }).count >= Self.sampleRate / fr else { return nil }
        if levels.suffix(pauseFrames).allSatisfy({ $0 < th }) {
            // The phrase boundary for this pause, when there is one, so the two agree exactly.
            let cut = cutAfterSpeech(pauseFrames: pauseFrames)
            if lastPhraseCut > lastCut, lastPhraseCut <= levels.count * fr,
               levels[(lastPhraseCut / fr)..<levels.count].allSatisfy({ $0 < th }) {
                return lastPhraseCut
            }
            return cut
        }
        // Too long without a pause: cut at the quietest frame of the last three seconds.
        if chunkFrames >= frames(maxChunkSeconds) {
            let from = max(start + 1, levels.count - 100)
            let quietest = (from..<levels.count).min { levels[$0] < levels[$1] } ?? levels.count - 1
            return quietest * fr
        }
        return nil
    }
}
