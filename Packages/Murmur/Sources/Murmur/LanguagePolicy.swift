import Foundation

/// Which language token whisper decodes each phrase with (decision D7: any language, switches
/// mid-dictation included).
///
/// whisper decodes a stretch of audio in one language. Given the wrong one, it does not keep the
/// speech as spoken: the English token translates Arabic into English, and the Arabic token writes
/// English and German in Arabic letters ("إشبرشن دويتش" for "Ich spreche Deutsch"). Two real
/// dictations on 8 October 2026 failed both ways. Synthetic voices hid the second failure (each
/// language had its own voice, and the Arabic token kept them apart); one voice speaking all three
/// reproduces it.
///
/// So every phrase (speech between pauses of 0.2 s or more) is decoded with its own language, the
/// strongest in its probe. The Arabic token also gets the mixed prompt, which keeps the English
/// terms Egyptian speakers use inside Arabic sentences in Latin script.
///
/// Short phrases (under 1.8 s) are probed less reliably, and when whisper can't tell it guesses
/// English or a stray language ("Genau, das passt." heard as English 83%, "تمام، ماشي." as
/// Hungarian). So a short phrase keeps its own language only when the probe is clear and not that
/// default guess; otherwise it takes its neighbour's (`shortPhrase`).
///
/// A long phrase whose probe is split between two languages was spoken in both without a pause.
/// A 1.5 s window slides along it every 0.5 s; where two windows in a row are clearly (70%) in one
/// language, that language holds there (`runs`), and the phrase is cut at the quietest point
/// between one run and the next. Arabic with a few English terms stays one Arabic stretch: a term
/// is far too short to fill two windows. Cutting mixed phrases into fixed 1.5 s parts instead was
/// worse than not cutting them (parts straddled the switch, and a German fragment decoded alone
/// with the Arabic token came out in Arabic letters).
///
/// English under 1.3 s next to another language is a term inside that language's sentence
/// ("اعمل custom property اسمها …", "Wir nutzen HubSpot für …"): it joins the sentence (`attachTerms`),
/// whose decode keeps it in Latin script; decoded alone it lost the words around it.
///
/// Measured and rejected: picking the language whisper is most confident in after decoding the
/// phrase both ways. Wrong-language output often scored higher (Arabic letters for English speech
/// had high token probabilities), 34 right out of 55.
public enum LanguagePolicy {
    public struct Decision: Equatable {
        public let code: String
        public let mixedPrompt: Bool

        public init(code: String, mixedPrompt: Bool) {
            self.code = code; self.mixedPrompt = mixedPrompt
        }
    }

    /// Phrases shorter than this have less reliable probes (see `shortPhrase`). On 55
    /// single-language phrases from five synthetic voices, every probe error was on a clip of
    /// 1.67 s or less.
    public static let minPhraseSeconds = 1.8
    /// Phrases shorter than this are not probed at all: they take a neighbour's language.
    public static let minProbeSeconds = 0.8
    /// Phrases at least this long are checked for a second language inside them (`mayBeMixed`).
    public static let mixedPhraseSeconds = 3.0
    /// English shorter than this next to another language is a term inside it (`attachTerms`).
    public static let termSeconds = 1.3
    /// The sliding window that finds where a mixed phrase switches language, and its step.
    public static let trackWindowSeconds = 1.5
    public static let trackStepSeconds = 0.5

    /// How a phrase in `code` is decoded.
    public static func route(_ code: String) -> Decision {
        Decision(code: code, mixedPrompt: code == "ar")
    }

    /// The language forced by the user's setting, nil in AUTO.
    public static func forced(_ mode: Lang) -> String? {
        switch mode {
        case .english: return "en"
        case .arabic: return "ar"
        case .auto: return nil
        }
    }

    /// The strongest language in a probe.
    public static func top(_ probe: [String: Float]?) -> String? {
        probe?.max(by: { $0.value < $1.value })?.key
    }

    /// A short phrase's own language, or nil to take a neighbour's: the probe must be clear (50%)
    /// and, when it says English (whisper's guess for audio it can't place), very clear (90%).
    public static func shortPhrase(_ probe: [String: Float]?) -> String? {
        guard let probe, let top = probe.max(by: { $0.value < $1.value }), top.value >= 0.5 else { return nil }
        return top.key != "en" || top.value >= 0.9 ? top.key : nil
    }

    /// A probe that may cover more than one language: the strongest under 90% and the next at
    /// 10% or more. Such a phrase is tracked window by window (`runs`), which decides whether it
    /// really switches; Arabic with a few English terms usually looks like this and stays whole.
    public static func mayBeMixed(_ probe: [String: Float]?) -> Bool {
        guard let probe else { return false }
        let shares = probe.values.sorted(by: >)
        return shares.count >= 2 && shares[0] < 0.9 && shares[1] >= 0.1
    }

    /// A window's strongest language and its share; nil when the window couldn't be probed.
    public static func strongest(_ probe: [String: Float]?) -> (language: String, share: Float)? {
        probe?.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    /// The runs along a phrase: two or more windows in a row clearly (70%) in one language, in
    /// order, with the indices of their first and last window. Fewer windows cover the ends of a
    /// phrase, so a lone window there counts when it is very clear (90%). Unclear and other lone
    /// windows are ignored; consecutive runs of one language merge.
    public static func runs(_ windows: [(language: String, share: Float)?]) -> [(language: String, first: Int, last: Int)] {
        let clear = windows.map { w in w.flatMap { $0.share >= 0.7 ? $0.language : nil } }
        var out: [(language: String, first: Int, last: Int)] = []
        var i = 0
        while i < clear.count {
            guard let l = clear[i] else { i += 1; continue }
            var j = i
            while j + 1 < clear.count, clear[j + 1] == l { j += 1 }
            let edge = (i == 0 || j == clear.count - 1) && (windows[i]?.share ?? 0) >= 0.9
            if j > i || edge {
                if let last = out.last, last.language == l { out[out.count - 1].last = j } else { out.append((l, i, j)) }
            }
            i = j + 1
        }
        return out
    }

    /// English stretches shorter than `termSeconds` take the language of the stretch before them
    /// (or after, or `before` at the start) when that is another language.
    public static func attachTerms(_ langs: [String?], seconds: [Double], before: String?) -> [String?] {
        var out = langs
        for i in out.indices where out[i] == "en" && seconds[i] < termSeconds {
            let prev = i > 0 ? out[i - 1] : before
            let next = i + 1 < out.count ? out[i + 1] : nil
            if let host = [prev, next].compactMap({ $0 }).first(where: { $0 != "en" }) { out[i] = host }
        }
        return out
    }

    /// Fills in the phrases that had no language of their own (nil): each takes the previous
    /// phrase's language, a phrase at the start of the piece takes the next one's, and a piece with
    /// none at all takes `before` (the language last used in this dictation). Nil only when there
    /// is nothing to go on.
    public static func resolve(_ heard: [String?], before: String?) -> [String?] {
        var out = heard
        for i in out.indices where out[i] == nil {
            out[i] = i > 0 ? out[i - 1] : nil
            if out[i] == nil { out[i] = heard[(i + 1)...].lazy.compactMap { $0 }.first ?? before }
        }
        return out
    }
}
