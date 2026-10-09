import AppKit
import Combine
import Foundation

public enum DictationPhase: Equatable {
    case idle
    case recording(locked: Bool, paused: Bool)
    case transcribing
    case done(text: String, pasted: Bool)
    case failed(String)
    case warning(String)
}

/// What the HUD and the menu show about the current dictation.
public final class DictationState: ObservableObject {
    @Published public var phase: DictationPhase = .idle
    @Published public var level: Float = 0
    @Published public var levels: [Float] = Array(repeating: 0, count: 12)
    @Published public var elapsed: TimeInterval = 0
    @Published public var lang: Lang = DictationPrefs.lang
    @Published public var armed: Bool = false
    @Published public var autoPaste: Bool = DictationPrefs.autoPaste
    @Published public var sounds: Bool = DictationPrefs.sounds
    @Published public var totalWords: Int = DictationPrefs.totalWords
    @Published public var pasteLastKey: String = DictationPrefs.pasteLastKey
    @Published public var copyLastKey: String = DictationPrefs.copyLastKey
    @Published public var keepModelMinutes: Int = DictationPrefs.keepModelMinutes
    @Published public var keepRecordings: Bool = DictationPrefs.keepRecordings

    public init() {}

    public var isBusy: Bool {
        switch phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }
    public var isLocked: Bool {
        if case .recording(true, _) = phase { return true }
        return false
    }

    public var onPauseToggle: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onCancel: (() -> Void)?

    public func pushLevel(_ v: Float) {
        levels.removeFirst()
        levels.append(v)
    }

    public func cycleLang() {
        lang = lang.next
        DictationPrefs.lang = lang
        DictationSound.tick()
    }
}

public enum DictationSound {
    public static func start() { play("Tink") }
    public static func stop()  { play("Pop") }
    public static func ok()    { play("Glass") }
    public static func fail()  { play("Basso") }
    public static func tick()  { play("Tink") }
    private static func play(_ name: String) {
        guard DictationPrefs.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

public enum Permissions {
    /// Accessibility is required both to observe the chord and to send the paste keystroke.
    public static var accessibility: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    public static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
