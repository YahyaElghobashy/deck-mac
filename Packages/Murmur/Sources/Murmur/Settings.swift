import Carbon.HIToolbox
import Foundation

// Deck's dictation module, Murmur. Hold ⌃⌥Z to talk; double-tap it to lock hands-free;
// ⌃⌥. cycles the language. Whisper runs locally, the text is pasted at the
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

/// Which whisper model transcribes dictation (decision D7, amended 9 October 2026: the user picks).
/// Measured on the synthetic sets with Deck 1.3.0: Accurate makes fewer mistakes (Egyptian Arabic
/// WER 7.3% → 4.2%, English terms kept 89% → 94%) and the text arrives about twice as late.
public enum SpeechModel: String, CaseIterable {
    case fast, accurate

    /// The model file, next to the fast model's (DeckSettings.whisperModelPath).
    public var fileName: String { self == .fast ? "ggml-large-v3-turbo.bin" : "ggml-large-v3.bin" }
    public var label: String { self == .fast ? "Fast" : "Accurate" }
    public var whisperName: String { self == .fast ? "large-v3-turbo" : "large-v3" }
    /// Memory while loaded, as shown in the menu.
    public var loadedGB: String { self == .fast ? "1.9" : "3.8" }

    /// This model's file in the folder of `fastModelPath`.
    public func path(besides fastModelPath: String) -> String {
        let fast = NSString(string: fastModelPath).expandingTildeInPath
        guard self == .accurate else { return fast }
        return (NSString(string: fast).deletingLastPathComponent as NSString).appendingPathComponent(fileName)
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
    /// AUTO by default: whisper detects the language and the mixed prompt keeps code-switching (D7).
    public static var lang: Lang {
        get { Lang(rawValue: d.string(forKey: "dictation.lang") ?? "auto") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "dictation.lang") }
    }
    /// One-time move to AUTO for anyone who had a fixed language before decision D7.
    public static func adoptAutoLanguageOnce() {
        guard d.object(forKey: "dictation.autoAdopted") == nil else { return }
        lang = .auto
        d.set(true, forKey: "dictation.autoAdopted")
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
    /// Minutes the speech model stays in memory after the last dictation; 0 keeps it until quit.
    public static var keepModelMinutes: Int {
        get { d.object(forKey: "dictation.keepModelMinutes") == nil ? 10 : d.integer(forKey: "dictation.keepModelMinutes") }
        set { d.set(newValue, forKey: "dictation.keepModelMinutes") }
    }
    public static var model: SpeechModel {
        get { SpeechModel(rawValue: d.string(forKey: "dictation.model") ?? "") ?? .fast }
        set { d.set(newValue.rawValue, forKey: "dictation.model") }
    }
    /// Keep recent recordings on this Mac for troubleshooting (KeptRecordings). On unless turned off.
    public static var keepRecordings: Bool {
        get { d.object(forKey: "dictation.keepRecordings") == nil ? true : d.bool(forKey: "dictation.keepRecordings") }
        set { d.set(newValue, forKey: "dictation.keepRecordings") }
    }
    /// The app build whose Metal shaders have been compiled for the model (see `warmIfNewBuild`).
    public static var warmedBuild: String {
        get { d.string(forKey: "dictation.warmedBuild") ?? "" }
        set { d.set(newValue, forKey: "dictation.warmedBuild") }
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
    /// A press shorter than this is a tap, not push-to-talk.
    public static let tapMaxSeconds: TimeInterval = 0.30
    /// A second press this soon after a tap locks hands-free.
    public static let doubleTapWindow: TimeInterval = 0.40
    public static let silenceRMSFloor: Float = 0.004
}
