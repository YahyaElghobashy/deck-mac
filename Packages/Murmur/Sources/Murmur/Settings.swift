import Carbon.HIToolbox
import Foundation

// Deck's dictation module, Murmur. Hold ⌃⌥Z to talk; tap Z again while ⌃⌥ is still held to
// lock hands-free; ⌃⌥. cycles the language. Whisper runs locally, the text is pasted at the
// cursor, the audio is deleted on every path.

public enum DictationPaths {
    /// Where the whisper model lives. The host app points this at its own setting; the default is
    /// large-v3-turbo in the standard models folder.
    public static var modelPathProvider: () -> String = { "~/.local/share/whisper-models/ggml-large-v3-turbo.bin" }

    public static var model: String { NSString(string: modelPathProvider()).expandingTildeInPath }
    public static var whisperCandidates: [String] {
        var list: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/whisper-cli").path { list.append(bundled) }
        return list + ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper"]
    }
    public static var whisper: String? { whisperCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    public static var modelExists: Bool { FileManager.default.fileExists(atPath: model) }
}

/// Primary language. whisper decides one language per clip, so forcing the dominant one
/// beats auto-detect on code-switched speech.
public enum Lang: String, CaseIterable {
    case english = "en"
    case arabic = "ar"
    case auto = "auto"

    public var label: String {
        switch self {
        case .english: return "EN"
        case .arabic: return "AR"
        case .auto: return "AUTO"
        }
    }
    public var long: String {
        switch self {
        case .english: return "English, with Arabic mixed in"
        case .arabic: return "Arabic, with English mixed in"
        case .auto: return "Detect automatically"
        }
    }
    public var next: Lang {
        switch self {
        case .english: return .arabic
        case .arabic: return .auto
        case .auto: return .english
        }
    }
}

public enum DictationPrefs {
    private static let d = UserDefaults.standard
    /// One-time import of Murmur's settings and word count.
    public static func migrateFromMurmur() {
        guard d.object(forKey: "dictation.migrated") == nil else { return }
        if let m = UserDefaults(suiteName: "com.yahyaelghobashy.murmur") {
            if let l = m.string(forKey: "lang") { d.set(l, forKey: "dictation.lang") }
            if m.object(forKey: "sounds") != nil { d.set(m.bool(forKey: "sounds"), forKey: "dictation.sounds") }
            if m.object(forKey: "autoPaste") != nil { d.set(m.bool(forKey: "autoPaste"), forKey: "dictation.autoPaste") }
            d.set(m.integer(forKey: "totalWords"), forKey: "dictation.totalWords")
        }
        d.set(true, forKey: "dictation.migrated")
    }
    public static var lang: Lang {
        get { Lang(rawValue: d.string(forKey: "dictation.lang") ?? "en") ?? .english }
        set { d.set(newValue.rawValue, forKey: "dictation.lang") }
    }
    public static var sounds: Bool {
        get { d.object(forKey: "dictation.sounds") == nil ? true : d.bool(forKey: "dictation.sounds") }
        set { d.set(newValue, forKey: "dictation.sounds") }
    }
    public static var autoPaste: Bool {
        get { d.object(forKey: "dictation.autoPaste") == nil ? true : d.bool(forKey: "dictation.autoPaste") }
        set { d.set(newValue, forKey: "dictation.autoPaste") }
    }
    public static var totalWords: Int {
        get { d.integer(forKey: "dictation.totalWords") }
        set { d.set(newValue, forKey: "dictation.totalWords") }
    }
    /// Letter for ⌃⌥<letter> that pastes the last dictation again.
    public static var pasteLastKey: String {
        get { d.string(forKey: "dictation.pasteLastKey") ?? "v" }
        set { d.set(newValue, forKey: "dictation.pasteLastKey") }
    }
    /// Letter for ⌃⌥<letter> that copies the last dictation.
    public static var copyLastKey: String {
        get { d.string(forKey: "dictation.copyLastKey") ?? "c" }
        set { d.set(newValue, forKey: "dictation.copyLastKey") }
    }
}

/// Physical key codes for ⌃⌥<letter> shortcuts. Positions, not characters, so they work the same
/// with the Arabic layout active.
public enum DictationKeys {
    public static let letters: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    ]
    public static func code(for letter: String) -> Int? { letters[letter.lowercased()] }
}

/// The most recent dictation, for paste-last and copy-last. Kept for 24 hours, in memory.
public enum LastDictation {
    public static let lifetime: TimeInterval = 24 * 3600
    private static var stored: (text: String, at: Date)?

    public static func record(_ text: String, at date: Date = Date()) { stored = (text, date) }
    public static var text: String? {
        guard let s = stored, Date().timeIntervalSince(s.at) < lifetime else { return nil }
        return s.text
    }
}

public enum DictationLimits {
    public static let maxRecordSeconds: TimeInterval = 120
    public static let minRecordSeconds: TimeInterval = 0.4
    public static let transcribeTimeout: TimeInterval = 90
    public static let doubleTapWindow: TimeInterval = 0.45
    public static let silenceRMSFloor: Float = 0.004
}
