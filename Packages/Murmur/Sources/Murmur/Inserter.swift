import AppKit
import ApplicationServices
import Foundation

public enum Inserter {
    /// How the last delivery landed, for logs and the paste check that follows it.
    public private(set) static var lastMethod: PasteMethod = .clipboard

    /// Pastes into the focused field when it accepts text, with the user's clipboard put back
    /// afterwards. When there is nowhere to paste, the transcript stays on the clipboard.
    /// `force` pastes even with auto-paste off, for an explicit "paste last".
    public static func deliver(_ text: String, force: Bool = false) -> Bool {
        let target = (force || DictationPrefs.autoPaste) && Permissions.accessibility ? PasteTarget.current() : nil
        guard let target, target.acceptsText else {
            ClipboardSession.shared.put(text, restore: false)
            lastMethod = .clipboard
            return false
        }
        ClipboardSession.shared.put(text, restore: true)
        guard let method = PasteLadder.paste(text, into: target) else {
            ClipboardSession.shared.put(text, restore: false)
            lastMethod = .clipboard
            return false
        }
        lastMethod = method
        return true
    }
}
