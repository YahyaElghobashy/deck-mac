import Foundation

/// The text whisper reads before the audio. whisper treats it as what was said just before, so it
/// steers spelling, script and style. Two jobs here:
///
/// - Keep code-switched speech in both scripts. Without a mixed example, whisper in AUTO dropped
///   every Arabic word of a mixed clip; with one, each word stayed in its own language and script.
/// - Spell names and terms the way the user does (HubSpot, n8n, lifecycle stage…).
///
/// whisper keeps at most about 224 prompt tokens, and Arabic costs more tokens per word, so the
/// parts are short and the previous chunk's text is trimmed to its last few words.
public enum SpeechPrompt {
    /// A mixed Egyptian Arabic and English sentence, as people actually talk at work.
    static let mixedExample = "يعني عايز أعمل workflow في HubSpot عشان ال deal stage يتحدث، and then we sync the contacts."
    /// A little Egyptian Arabic, so dialect words aren't pulled toward Modern Standard Arabic.
    static let egyptianHint = "أنا عايز أخلص الحاجة دي النهارده، ماشي؟"

    /// Terms to spell right. Replaced by the user's own vocabulary list when that lands (PER-01).
    public static var vocabulary: [String] = [
        "HubSpot", "Salesforce", "ClickUp", "Slack", "n8n", "Zapier", "Stripe", "Fathom",
        "webhook", "API key", "workflow", "pipeline", "deal stage", "lifecycle stage", "MQL", "custom property",
    ]

    /// The prompt for one dictation or chunk. `previous` is the text already transcribed in this
    /// dictation, which keeps chunks consistent with each other.
    public static func build(lang: Lang, previous: String? = nil) -> String {
        build(mixed: lang != .english, previous: previous)
    }

    /// The Arabic route (Arabic token): the terms inside an Arabic sentence ("we use HubSpot and
    /// Slack and …"), the dialect hint, the mixed example, then the terms as a plain English list.
    /// With the Arabic token forced on all 30 synthetic clips, this order gave the best English
    /// (WER 3.9%, one Arabic-script word leaking into English text against four for the order
    /// without the closing list) while keeping 94% of English terms in mixed speech.
    /// The English route: the terms as a plain English list.
    public static func build(mixed: Bool, previous: String? = nil) -> String {
        var parts: [String] = []
        if mixed, !vocabulary.isEmpty { parts.append("بنستخدم " + vocabulary.joined(separator: " و ") + ".") }
        if mixed {
            parts.append(egyptianHint)
            parts.append(mixedExample)
        }
        if !vocabulary.isEmpty { parts.append("Terms: " + vocabulary.joined(separator: ", ") + ".") }
        if let previous, !previous.isEmpty {
            parts.append(previous.split(separator: " ").suffix(20).joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }

    /// whisper sometimes returns its prompt, or a piece of it, when the audio holds no speech.
    /// True when `text` is nothing but prompt material, so the result can be dropped.
    public static func isEcho(_ text: String, of prompt: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t.count >= 6 && prompt.contains(t)
    }
}
