import AppKit
import ApplicationServices
import Carbon
import Foundation

/// How a dictation reached the focused field.
public enum PasteMethod: String {
    case keystroke   // ⌘V with the layout's own key for V
    case menu        // the app's Edit ▸ Paste, pressed through Accessibility
    case selection   // the text written straight into the field's selection
    case clipboard   // nowhere to paste: left on the clipboard
}

/// The focused element and its app, read through Accessibility.
struct PasteTarget {
    let app: AXUIElement?
    let bundleID: String?
    let focused: AXUIElement?
    let acceptsText: Bool

    /// Editors and terminals that take a paste even when their text view doesn't say so.
    static let knownTextApps: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "com.tinyspeck.slackmacgap", "com.mitchellh.ghostty",
    ]
    static let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]

    static func current() -> PasteTarget {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front.map { AXUIElementCreateApplication($0.processIdentifier) }
        var focused = copyFocused()
        // Electron apps (VS Code, Cursor, Slack) build their accessibility tree only when asked.
        if focused == nil, let app {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            focused = copyFocused()
        }
        let bundleID = front?.bundleIdentifier
        let accepts = focused.map(Self.acceptsText) ?? false
        return PasteTarget(app: app, bundleID: bundleID, focused: focused,
                           acceptsText: accepts || bundleID.map(knownTextApps.contains) == true)
    }

    private static func copyFocused() -> AXUIElement? {
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private static func acceptsText(_ el: AXUIElement) -> Bool {
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if textRoles.contains(roleRef as? String ?? "") { return true }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }
}

enum PasteLadder {
    /// Tries ⌘V, then Edit ▸ Paste, then writing the selection. The text is already on the clipboard.
    static func paste(_ text: String, into target: PasteTarget) -> PasteMethod? {
        if !IsSecureEventInputEnabled(), postCommandV() { return .keystroke }
        if let app = target.app, pressPasteMenuItem(app) { return .menu }
        if let el = target.focused,
           AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return .selection }
        return nil
    }

    static func postCommandV() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        src.setLocalEventsFilterDuringSuppressionState([.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                       state: .eventSuppressionStateSuppressionInterval)
        let v = KeyLayout.commandKeyCode(for: "v")
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Finds the enabled menu item whose shortcut is plain ⌘V, whatever the menu is called in
    /// the app's language, and presses it.
    static func pressPasteMenuItem(_ app: AXUIElement) -> Bool {
        guard let menuBar = attribute(app, kAXMenuBarAttribute) else { return false }
        for top in children(menuBar) {
            for menu in children(top) {
                for item in children(menu) {
                    guard (attribute(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "V",
                          (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0,
                          (attribute(item, kAXEnabledAttribute) as? Bool) == true else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }
    private static func children(_ el: AnyObject) -> [AXUIElement] {
        guard CFGetTypeID(el) == AXUIElementGetTypeID() else { return [] }
        return (attribute(el as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}

/// Which physical key types a character when ⌘ is held, for the active keyboard layout.
public enum KeyLayout {
    /// The key code for `char` on the ⌘ layer of the current layout; when that layout has no such
    /// key (Arabic, for example), the layout macOS uses for shortcuts; otherwise the ANSI position.
    public static func commandKeyCode(for char: Character) -> CGKeyCode {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for source in sources {
            guard let src = source?.takeRetainedValue(), let code = keyCode(for: char, in: src) else { continue }
            return code
        }
        return CGKeyCode(kVK_ANSI_V)
    }

    public static func keyCode(for char: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(char).lowercased()
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<UInt16(128) {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
