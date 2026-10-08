import AppKit
import ApplicationServices
import Foundation

public enum Inserter {
    /// Clipboard first, then ⌘V into the focused field when it accepts text. The clipboard keeps
    /// the transcript either way.
    public static func deliver(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard DictationPrefs.autoPaste, Permissions.accessibility, focusedAcceptsText() else { return false }
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        src.setLocalEventsFilterDuringSuppressionState([.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                       state: .eventSuppressionStateSuppressionInterval)
        let v: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
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
