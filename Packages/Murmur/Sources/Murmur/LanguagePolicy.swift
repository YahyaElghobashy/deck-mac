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
/// In AUTO, from the probe taken while recording: ≥ 95% English → English; English and Arabic
/// together ≥ 50% → Arabic with the mixed prompt; anything else → the language whisper hears.
public enum LanguagePolicy {
    public struct Decision: Equatable {
        public let code: String
        public let mixedPrompt: Bool
    }

    /// English plus Arabic at or above this share of the detected language means "his languages".
    public static let enArShare: Float = 0.5
    /// At or above this, the speech is treated as purely English.
    public static let pureEnglish: Float = 0.95
    /// How much audio the in-recording language probe listens to.
    public static let probeSeconds: Double = 2.0

    public static func decide(mode: Lang, probe: [String: Float]?) -> Decision {
        switch mode {
        case .english:
            return Decision(code: "en", mixedPrompt: false)
        case .arabic:
            return Decision(code: "ar", mixedPrompt: true)
        case .auto:
            guard let probe, let top = probe.max(by: { $0.value < $1.value }) else {
                return Decision(code: "ar", mixedPrompt: true)        // too short to probe: his languages
            }
            if (probe["en"] ?? 0) >= pureEnglish { return Decision(code: "en", mixedPrompt: false) }
            if (probe["en"] ?? 0) + (probe["ar"] ?? 0) >= enArShare { return Decision(code: "ar", mixedPrompt: true) }
            return Decision(code: top.key, mixedPrompt: false)
        }
    }

    /// The language actually spoken, for history and metrics: the probe's best guess when there is one.
    public static func spoken(probe: [String: Float]?, decision: Decision) -> String {
        probe?.max(by: { $0.value < $1.value })?.key ?? decision.code
    }
}
