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

    /// The prompt for a whole recording decoded in one language (bench, whisper-cli fallback).
    public static func build(lang: Lang, previous: String? = nil) -> String {
        build(language: LanguagePolicy.forced(lang) ?? "ar", previous: previous)
    }

    /// The prompt for a stretch decoded in `language`. `previous` is the text already transcribed
    /// in that language in this dictation, which keeps the pieces consistent with each other.
    ///
    /// Arabic (the mixed route): the terms inside an Arabic sentence ("we use HubSpot and Slack
    /// and …"), the dialect hint, the mixed example, then the terms as a plain English list. With
    /// the Arabic token on all 30 synthetic clips, this order kept 94% of English terms in mixed
    /// speech. Any other language: the terms as a plain list.
    public static func build(language: String, previous: String? = nil) -> String {
        var parts: [String] = []
        if language == "ar" {
            if !vocabulary.isEmpty { parts.append("بنستخدم " + vocabulary.joined(separator: " و ") + ".") }
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
    /// True when `text` is nothing but a sizeable piece of the prompt, so the result can be dropped.
    /// At least 20 characters: a term said on its own ("HubSpot", "workflow") is in the prompt's
    /// term list too, and a shorter limit deleted it.
    public static func isEcho(_ text: String, of prompt: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t.count >= 20 && prompt.contains(t)
    }
}
