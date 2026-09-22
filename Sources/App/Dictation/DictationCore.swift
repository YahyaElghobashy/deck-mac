import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

// Deck's dictation module — Murmur, folded in. Hold ⌃⌥Z to talk; tap Z again while ⌃⌥ is
// still held to lock hands-free; ⌃⌥. cycles the language. Whisper runs locally, the text is
// pasted at the cursor, the audio is deleted on every path.

enum DictationPaths {
    /// Whichever model Settings (or the suite installer) points at; defaults to large-v3-turbo.
    static var model: String { NSString(string: DeckSettings.load().whisperModelPath).expandingTildeInPath }
    static var whisperCandidates: [String] {
        var list: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/whisper-cli").path { list.append(bundled) }
        return list + ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper"]
    }
    static var whisper: String? { whisperCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var modelExists: Bool { FileManager.default.fileExists(atPath: model) }
}

/// Primary language. whisper decides one language per clip, so forcing the dominant one
/// beats auto-detect on code-switched speech.
enum Lang: String, CaseIterable {
    case english = "en"
    case arabic = "ar"
    case auto = "auto"

    var label: String {
        switch self {
        case .english: return "EN"
        case .arabic: return "AR"
        case .auto: return "AUTO"
        }
    }
    var long: String {
        switch self {
        case .english: return "English, with Arabic mixed in"
        case .arabic: return "Arabic, with English mixed in"
        case .auto: return "Detect automatically"
        }
    }
    var next: Lang {
        switch self {
        case .english: return .arabic
        case .arabic: return .auto
        case .auto: return .english
        }
    }
}

enum DictationPrefs {
    private static let d = UserDefaults.standard
    /// One-time import of Murmur's settings and word count.
    static func migrateFromMurmur() {
        guard d.object(forKey: "dictation.migrated") == nil else { return }
        if let m = UserDefaults(suiteName: "com.yahyaelghobashy.murmur") {
            if let l = m.string(forKey: "lang") { d.set(l, forKey: "dictation.lang") }
            if m.object(forKey: "sounds") != nil { d.set(m.bool(forKey: "sounds"), forKey: "dictation.sounds") }
            if m.object(forKey: "autoPaste") != nil { d.set(m.bool(forKey: "autoPaste"), forKey: "dictation.autoPaste") }
            d.set(m.integer(forKey: "totalWords"), forKey: "dictation.totalWords")
        }
        d.set(true, forKey: "dictation.migrated")
    }
    static var lang: Lang {
        get { Lang(rawValue: d.string(forKey: "dictation.lang") ?? "en") ?? .english }
        set { d.set(newValue.rawValue, forKey: "dictation.lang") }
    }
    static var sounds: Bool {
        get { d.object(forKey: "dictation.sounds") == nil ? true : d.bool(forKey: "dictation.sounds") }
        set { d.set(newValue, forKey: "dictation.sounds") }
    }
    static var autoPaste: Bool {
        get { d.object(forKey: "dictation.autoPaste") == nil ? true : d.bool(forKey: "dictation.autoPaste") }
        set { d.set(newValue, forKey: "dictation.autoPaste") }
    }
    static var totalWords: Int {
        get { d.integer(forKey: "dictation.totalWords") }
        set { d.set(newValue, forKey: "dictation.totalWords") }
    }
}

enum DictationLimits {
    static let maxRecordSeconds: TimeInterval = 120
    static let minRecordSeconds: TimeInterval = 0.4
    static let transcribeTimeout: TimeInterval = 90
    static let doubleTapWindow: TimeInterval = 0.45
    static let silenceRMSFloor: Float = 0.004
}

enum DictationPhase: Equatable {
    case idle
    case recording(locked: Bool, paused: Bool)
    case transcribing
    case done(text: String, pasted: Bool)
    case failed(String)
    case warning(String)
}

final class DictationState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 12)
    @Published var elapsed: TimeInterval = 0
    @Published var lang: Lang = DictationPrefs.lang
    @Published var armed: Bool = false
    @Published var autoPaste: Bool = DictationPrefs.autoPaste
    @Published var sounds: Bool = DictationPrefs.sounds
    @Published var totalWords: Int = DictationPrefs.totalWords

    var isBusy: Bool {
        switch phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }
    var isLocked: Bool {
        if case .recording(true, _) = phase { return true }
        return false
    }

    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    func pushLevel(_ v: Float) {
        levels.removeFirst()
        levels.append(v)
    }

    func cycleLang() {
        lang = lang.next
        DictationPrefs.lang = lang
        DictationSound.tick()
    }
}

enum DictationSound {
    static func start() { play("Tink") }
    static func stop()  { play("Pop") }
    static func ok()    { play("Glass") }
    static func fail()  { play("Basso") }
    static func tick()  { play("Tink") }
    private static func play(_ name: String) {
        guard DictationPrefs.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

enum Permissions {
    /// Accessibility is required both to observe the chord and to send the paste keystroke.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

// MARK: - Global chord

/// Watches ⌃⌥Z (hold to talk) and ⌃⌥. (cycle language) through a session event tap and
/// swallows both so the characters never reach the focused app. The lock gesture is a second
/// Z tap while ⌃⌥ are still held: a modifier release in between resets the chain.
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastPressAt: TimeInterval = 0
    private var isDown = false
    private var modsHeld = false

    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onCycleLang: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var running = false

    func start() -> Bool {
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

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        tap = nil; source = nil; running = false
    }

    /// macOS disables a tap that ever blocks. Re-enable rather than dying silently.
    func reenableIfNeeded() {
        if let t = tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        if type == .flagsChanged {
            let both = flags.contains(.maskControl) && flags.contains(.maskAlternate)
            if both { modsHeld = true } else { modsHeld = false; lastPressAt = 0 }
            return Unmanaged.passUnretained(event)
        }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let chord = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        let noCmd = !flags.contains(.maskCommand)

        if type == .keyDown, chord, noCmd, code == kVK_ANSI_Period {
            DispatchQueue.main.async { self.onCycleLang?() }
            return nil
        }

        if chord, noCmd, code == kVK_ANSI_Z {
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                let now = Date().timeIntervalSince1970
                let isDouble = modsHeld && (now - lastPressAt) < DictationLimits.doubleTapWindow
                lastPressAt = now
                modsHeld = true
                isDown = true
                DispatchQueue.main.async { isDouble ? self.onDoubleTap?() : self.onPressStart?() }
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
