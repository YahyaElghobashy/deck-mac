import AppKit
import ApplicationServices
import Foundation

public enum Inserter {
    /// ⌘V into the focused field when it accepts text, with the user's clipboard put back
    /// afterwards. When there is nowhere to paste, the transcript stays on the clipboard.
    public static func deliver(_ text: String) -> Bool {
        guard DictationPrefs.autoPaste, Permissions.accessibility, focusedAcceptsText(),
              let (down, up) = pasteKeystroke() else {
            ClipboardSession.shared.put(text, restore: false)
            return false
        }
        ClipboardSession.shared.put(text, restore: true)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private static func pasteKeystroke() -> (CGEvent, CGEvent)? {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return nil }
        src.setLocalEventsFilterDuringSuppressionState([.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                       state: .eventSuppressionStateSuppressionInterval)
        let v: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }

    private static func focusedAcceptsText() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return false }
        let el = element as! AXUIElement
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        if textRoles.contains(role) { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        return false
    }
}
