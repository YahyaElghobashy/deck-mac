import Foundation

/// Which language token whisper decodes with, and whether the mixed Arabic and English prompt goes
/// with it (decision D7: any language, switches mid-sentence included).
///
/// Measured on the synthetic test set: decoding English, Arabic and mixed speech with the Arabic
/// token plus the mixed prompt keeps English words in Latin script and Arabic in Arabic, cuts mixed
/// error rates (WER 26% → 19%, CER 19% → 8%) and halves decoding time (0.9 s → 0.43 s). Letting
/// whisper detect the language instead picked English for whole mixed clips and romanized the
/// Arabic. But the Arabic token sometimes turned the first word of a purely English sentence into
/// Arabic script, so speech the probe hears as almost entirely English decodes as English.
///
/// The first real dictation (English, Egyptian Arabic and German in 13 s) showed the danger of the
/// English token: whisper translates whatever doesn't match it, so the Arabic came out in English.
/// The Arabic route kept German, English and Arabic each in its own language on the trilingual
/// test lines. So the English token is used only when there is no Arabic to lose.
///
/// In AUTO the evidence for a piece is the strongest share each language reached across its probes
/// (a language heard early and then drowned out still counts). From the languages clearly present
/// (≥ 6%): Arabic among them → Arabic route; English alone → English; one other language alone →
/// that language; English with another language → Arabic route, which kept German and English
/// intact on the test lines; anything else → the strongest language. English alone needs complete
/// evidence (see `decide`).
public enum LanguagePolicy {
    public struct Decision: Equatable {
        public let code: String
        public let mixedPrompt: Bool
        /// The evidence heard only English, but it was partial so the Arabic route was taken anyway.
        /// The transcriber then drops a stray Arabic-script first word from all-Latin text.
        public var englishOnlyEvidence = false

        public init(code: String, mixedPrompt: Bool, englishOnlyEvidence: Bool = false) {
            self.code = code; self.mixedPrompt = mixedPrompt; self.englishOnlyEvidence = englishOnlyEvidence
        }
    }

    /// A language at or above this share is "clearly present" in a piece.
    public static let present: Float = 0.06
    /// How much audio the in-recording language probe listens to.
    public static let probeSeconds: Double = 2.0

    /// `complete` says the probe heard (nearly) the whole piece. Only complete evidence may choose
    /// the English token, since the English token translates anything said after the probe stopped
    /// listening; partial evidence of English alone takes the Arabic route.
    public static func decide(mode: Lang, probe: [String: Float]?, complete: Bool = true) -> Decision {
        switch mode {
        case .english:
            return Decision(code: "en", mixedPrompt: false)
        case .arabic:
            return Decision(code: "ar", mixedPrompt: true)
        case .auto:
            guard let probe, let top = probe.max(by: { $0.value < $1.value }) else {
                return Decision(code: "ar", mixedPrompt: true)        // too short to probe: his languages
            }
            let strong = Set(probe.filter { $0.value >= present }.map(\.key))
            if strong.contains("ar") { return Decision(code: "ar", mixedPrompt: true) }
            if strong == ["en"] {
                return complete ? Decision(code: "en", mixedPrompt: false)
                                : Decision(code: "ar", mixedPrompt: true, englishOnlyEvidence: true)
            }
            if strong.count == 1, let only = strong.first, complete || (probe[only] ?? 0) >= 0.9 {
                return Decision(code: only, mixedPrompt: false)
            }
            if strong.contains("en") || !complete { return Decision(code: "ar", mixedPrompt: true) }
            return Decision(code: top.key, mixedPrompt: false)
        }
    }

    /// Several probes of one piece combined: the strongest share each language reached.
    public static func merge(_ a: [String: Float]?, _ b: [String: Float]) -> [String: Float] {
        (a ?? [:]).merging(b) { max($0, $1) }
    }

    /// The language actually spoken, for history and metrics: the probe's best guess when there is one.
    public static func spoken(probe: [String: Float]?, decision: Decision) -> String {
        probe?.max(by: { $0.value < $1.value })?.key ?? decision.code
    }
}
