import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Watches ⌃⌥Z (hold to talk), ⌃⌥. (cycle language) and the paste-last and copy-last chords
/// through a session event tap and swallows them so the characters never reach the focused app. The lock gesture is a second
/// Z tap while ⌃⌥ are still held: a modifier release in between resets the chain.
public final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    /// Raw press and release of the dictation chord; ChordGesture tells taps from holds.
    public var onPressStart: (() -> Void)?
    public var onPressEnd: (() -> Void)?
    public var onCycleLang: (() -> Void)?
    public var onEscape: (() -> Void)?
    public var onPasteLast: (() -> Void)?
    public var onCopyLast: (() -> Void)?

    /// Key codes for ⌃⌥<key> paste-last and copy-last; nil turns a shortcut off.
    public var pasteLastCode: Int? = kVK_ANSI_V
    public var copyLastCode: Int? = kVK_ANSI_C

    public private(set) var running = false

    public init() {}

    /// The tap holds an unretained pointer to self, so it must not outlive the monitor.
    deinit { stop() }

    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        running = true
        return true
    }

    public func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        tap = nil; source = nil; running = false
    }

    /// macOS disables a tap that ever blocks. Re-enable rather than dying silently.
    public func reenableIfNeeded() {
        if let t = tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        if type == .flagsChanged { return Unmanaged.passUnretained(event) }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let chord = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        let noCmd = !flags.contains(.maskCommand)

        if type == .keyDown, chord, noCmd, code == kVK_ANSI_Period {
            DispatchQueue.main.async { self.onCycleLang?() }
            return nil
        }

        for (wanted, action) in [(pasteLastCode, onPasteLast), (copyLastCode, onCopyLast)] {
            guard chord, noCmd, let wanted, code == wanted else { continue }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { action?() }
            }
            return nil
        }

        if chord, noCmd, code == kVK_ANSI_Z {
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                isDown = true
                DispatchQueue.main.async { self.onPressStart?() }
            } else if type == .keyUp {
                isDown = false
                DispatchQueue.main.async { self.onPressEnd?() }
            }
            return nil
        }

        if type == .keyDown, code == kVK_Escape {
            DispatchQueue.main.async { self.onEscape?() }
        }
        return Unmanaged.passUnretained(event)
    }
}
