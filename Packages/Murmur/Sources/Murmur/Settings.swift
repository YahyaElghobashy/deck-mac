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
}

public enum DictationLimits {
    public static let maxRecordSeconds: TimeInterval = 120
    public static let minRecordSeconds: TimeInterval = 0.4
    public static let transcribeTimeout: TimeInterval = 90
    public static let doubleTapWindow: TimeInterval = 0.45
    public static let silenceRMSFloor: Float = 0.004
}
