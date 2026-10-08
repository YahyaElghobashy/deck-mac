import Foundation

/// Finds the places to cut a growing recording so each piece can be transcribed while the user is
/// still talking. Pure logic over 16 kHz samples: it looks at 30 ms frames, tracks the noise floor,
/// and cuts in the middle of a pause, never inside a word.
public struct PauseChunker {
    public static let sampleRate = 16_000
    static let frame = 480                        // 30 ms

    /// A chunk needs at least this much audio before a pause may end it.
    public var minChunkSeconds: Double = 4.0
    /// Silence at least this long counts as a pause.
    public var minPauseSeconds: Double = 0.5
    /// Past this, the chunk is cut at its quietest point even without a pause.
    public var maxChunkSeconds: Double = 25.0

    private var levels: [Float] = []              // RMS per frame, for the whole recording so far
    private var lastCut = 0                        // sample index of the last cut
    public private(set) var cuts: [Int] = []

    public init() {}

    /// Feeds the whole recording so far (it reads only what is new) and returns any new cut points,
    /// as sample indices into the recording.
    public mutating func feed(_ samples: [Float]) -> [Int] {
        var newCuts: [Int] = []
        let frames = samples.count / Self.frame
        while levels.count < frames {
            let start = levels.count * Self.frame
            var sum: Float = 0
            for i in start..<(start + Self.frame) { sum += samples[i] * samples[i] }
            levels.append((sum / Float(Self.frame)).squareRoot())
            if let cut = cutPoint() {
                cuts.append(cut); newCuts.append(cut); lastCut = cut
            }
        }
        return newCuts
    }

    /// Speech threshold: well above the noise floor (the quiet 10th percentile of the last ten
    /// seconds), and never below an absolute floor so a silent room isn't read as speech.
    private func threshold(upTo end: Int) -> Float {
        let window = levels[max(0, end - 333)..<end].sorted()
        let floor = window.isEmpty ? 0 : window[window.count / 10]
        return max(floor * 3.0, 0.006)
    }

    private func cutPoint() -> Int? {
        let fr = Self.frame
        let start = lastCut / fr
        let chunkFrames = levels.count - start
        let pauseFrames = Int(minPauseSeconds * Double(Self.sampleRate) / Double(fr))
        guard chunkFrames >= Int(minChunkSeconds * Double(Self.sampleRate) / Double(fr)) else { return nil }

        let th = threshold(upTo: levels.count)
        // Silence alone never becomes a chunk: whisper invents words for silent audio.
        guard levels[start..<levels.count].filter({ $0 >= th }).count >= Self.sampleRate / fr else { return nil }
        // The last half second is a pause: cut 0.15 s after the speech stopped. Cutting in the middle
        // of the pause left a soft word onset at the end of a piece, which whisper turned into an
        // extra word ("زيادة عميلة" for "زيادة … عشان").
        if levels.suffix(pauseFrames).allSatisfy({ $0 < th }) {
            return (levels.count - pauseFrames + 5) * fr
        }
        // Too long without a pause: cut at the quietest frame of the last three seconds.
        if chunkFrames >= Int(maxChunkSeconds * Double(Self.sampleRate) / Double(fr)) {
            let from = max(start + 1, levels.count - 100)
            let quietest = (from..<levels.count).min { levels[$0] < levels[$1] } ?? levels.count - 1
            return quietest * fr
        }
        return nil
    }
}
