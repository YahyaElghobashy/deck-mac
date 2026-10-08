import ApplicationServices
import Foundation

public enum PasteVerdict: String {
    case landed    // the field now holds the text
    case failed    // the field was readable before and after, and did not change
    case unknown   // the field can't be read (terminals, many Electron apps) or changed some other way
}

/// Checks that a paste arrived by reading the focused field through Accessibility before and after
/// (DEL-03). Only a field that is readable both times and provably unchanged counts as a failure,
/// so an unreadable field never raises a false alarm.
public enum PasteCheck {
    /// Fields longer than this aren't compared (a large document is slow to read and diff).
    static let maxLength = 100_000

    public static func verdict(before: String?, after: String?, inserted: String) -> PasteVerdict {
        guard let before, let after, before.count <= maxLength, after.count <= maxLength else { return .unknown }
        if after == before { return .failed }
        let probe = String(inserted.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if !probe.isEmpty, after.contains(probe) { return .landed }
        if after.count >= before.count + max(1, inserted.count / 2) { return .landed }
        return .unknown
    }

    static func readValue(_ element: AXUIElement?) -> String? {
        guard let element else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Reads the field 0.35 s after the paste, and once more at 0.6 s if it hasn't changed yet
    /// (slow apps), then reports. Main thread. The clipboard restore waits 0.8 s, so a failure is
    /// known before the transcript would leave the clipboard.
    static func watch(_ element: AXUIElement?, before: String?, inserted: String, report: @escaping (PasteVerdict) -> Void) {
        guard let element, before != nil else { return report(.unknown) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let first = verdict(before: before, after: readValue(element), inserted: inserted)
            guard first == .failed else { return report(first) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                report(verdict(before: before, after: readValue(element), inserted: inserted))
            }
        }
    }
}
