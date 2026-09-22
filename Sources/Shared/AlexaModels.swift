import Foundation

// Mirrors the bridge's alexa-state.json. Everything optional so a partial cache still decodes.

struct AlexaDevice: Codable, Identifiable, Hashable {
    var name: String
    var serial: String
    var family: String?
    var type: String?
    var online: Bool?
    var id: String { serial }
}

struct SmartEntity: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String?
    var category: String?
    var operations: [String]?
    var power: String?          // "ON" | "OFF"
    var brightness: Double?
    var percentage: Double?
    var temperature: Double?
    var targetTemp: Double?
    var mode: String?
    var reachable: Bool?

    var isOn: Bool { power == "ON" }
    var canToggle: Bool { (operations ?? []).contains(where: { $0.lowercased().contains("turnon") }) || power != nil }
}

struct AlexaNotification: Codable, Identifiable, Hashable {
    var id: String?
    var type: String            // Timer | Alarm | Reminder
    var label: String?
    var device: String?
    var endsAt: Double?         // ms since epoch
    var remainingMs: Double?

    var endDate: Date? { endsAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var uid: String { id ?? "\(type)-\(label ?? "")-\(endsAt ?? 0)" }
}

struct AlexaPlayer: Codable, Hashable {
    var device: String?
    var state: String?          // PLAYING | PAUSED | IDLE
    var title: String?
    var artist: String?
    var album: String?
    var imageURL: String?
    var provider: String?
    var progress: Double?
    var length: Double?
    var volume: Double?
    var muted: Bool?
    var isPlaying: Bool { state == "PLAYING" }
}

struct AlexaExchange: Codable, Hashable {
    var utterance: String?
    var response: String?
    var at: Double?
    var device: String?
    var note: String?
    var date: Date { Date(timeIntervalSince1970: (at ?? 0) / 1000) }
}

struct AlexaRoutine: Codable, Identifiable, Hashable {
    var id: String
    var name: String
}

struct AlexaState: Codable {
    var updatedAt: Double = 0
    var authenticated: Bool = false
    var loginUrl: String? = nil
    var loginError: String? = nil
    var amazonPage: String? = nil
    var defaultDevice: String? = nil
    var devices: [AlexaDevice] = []
    var smarthome: [SmartEntity] = []
    var notifications: [AlexaNotification] = []
    var player: AlexaPlayer? = nil
    var lastExchange: AlexaExchange? = nil
    var pending: AlexaExchange? = nil
    var routines: [AlexaRoutine] = []

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    static func load() -> AlexaState {
        guard let data = try? Data(contentsOf: DeckPaths.alexaState) else { return AlexaState() }
        let dec = JSONDecoder()
        if let s = try? dec.decode(AlexaState.self, from: data) { return s }
        DebugLog.write("alexa-state decode failed")
        return AlexaState()
    }

    func entity(named name: String) -> SmartEntity? {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let n = key(name)
        guard !n.isEmpty else { return nil }
        return smarthome.first { key($0.name) == n } ?? smarthome.first { key($0.name).hasPrefix(n) }
    }
}

// MARK: - User-configured tiles (actions.json)

enum TileKind: String, Codable { case entity, text, routine, listen }

struct Tile: Codable, Identifiable, Hashable {
    var id: String
    var kind: TileKind
    var label: String
    var symbol: String
    var color: String
    /// entity name (kind .entity), text command (kind .text), routine id (kind .routine)
    var target: String
    var device: String? = nil
    var enabled: Bool = true
}

struct DeckActions: Codable {
    var tiles: [Tile] = DeckActions.defaults

    static func load() -> DeckActions {
        guard let data = try? Data(contentsOf: DeckPaths.actions),
              let a = try? JSONDecoder().decode(DeckActions.self, from: data) else { return DeckActions() }
        return a
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) {
            try? FileManager.default.createDirectory(at: DeckPaths.dir, withIntermediateDirectories: true)
            try? d.write(to: DeckPaths.actions, options: .atomic)
        }
    }

    /// Yahya's list: rooms/devices as power tiles, the rest as typed commands.
    static let defaults: [Tile] = [
        Tile(id: "ac", kind: .entity, label: "A.C", symbol: "snowflake", color: "#8FB4C4", target: "A.C"),
        Tile(id: "tv", kind: .entity, label: "TV", symbol: "tv.fill", color: "#A78BFA", target: "TV"),
        Tile(id: "neon", kind: .entity, label: "Neon", symbol: "lightbulb.led.fill", color: "#D9724E", target: "Neon"),
        Tile(id: "space", kind: .entity, label: "Space", symbol: "sparkles", color: "#8B5CF6", target: "Space"),
        Tile(id: "bed", kind: .entity, label: "Bed", symbol: "bed.double.fill", color: "#F59E0B", target: "Bed"),
        Tile(id: "dresser", kind: .entity, label: "Dresser", symbol: "cabinet.fill", color: "#10B981", target: "Dresser"),
        Tile(id: "desk", kind: .entity, label: "Desk", symbol: "lamp.desk.fill", color: "#FACC15", target: "Desk"),
        Tile(id: "mirror", kind: .entity, label: "Mirror", symbol: "rectangle.portrait.fill", color: "#B8A99A", target: "Mirror"),
        Tile(id: "ac-cool", kind: .text, label: "AC cool", symbol: "wind.snow", color: "#8FB4C4", target: "set ac mode to cool"),
        Tile(id: "ac-20", kind: .text, label: "AC 20°", symbol: "thermometer.medium", color: "#8FB4C4", target: "set ac temperature to 20"),
        Tile(id: "ac-fan-high", kind: .text, label: "Fan high", symbol: "fan.fill", color: "#8FB4C4", target: "set ac fan speed to high"),
        Tile(id: "tv-mute", kind: .text, label: "Mute TV", symbol: "speaker.slash.fill", color: "#A78BFA", target: "mute tv"),
        Tile(id: "tv-unmute", kind: .text, label: "Unmute TV", symbol: "speaker.wave.2.fill", color: "#C4B5FD", target: "unmute tv"),
        Tile(id: "govee-dreamy", kind: .text, label: "Dreamy", symbol: "moon.stars.fill", color: "#EC4899", target: "set govee scene to dreamy"),
        Tile(id: "r-sleep", kind: .routine, label: "Sleep mode", symbol: "moon.zzz.fill", color: "#6366F1", target: "sleep mode"),
        Tile(id: "r-home", kind: .routine, label: "I'm home", symbol: "house.fill", color: "#34D399", target: "I'm home"),
        Tile(id: "r-leaving", kind: .routine, label: "Leaving", symbol: "figure.walk", color: "#F97316", target: "i am leaving"),
        Tile(id: "r-wake", kind: .routine, label: "Wake up", symbol: "sunrise.fill", color: "#FACC15", target: "Wake up"),
        Tile(id: "r-hot", kind: .routine, label: "I'm hot", symbol: "flame.fill", color: "#FF5A36", target: "i'm hot", enabled: false),
        Tile(id: "r-acmid", kind: .routine, label: "AC mid", symbol: "thermometer.low", color: "#8FB4C4", target: "ac mid", enabled: false),
        Tile(id: "r-acdesk", kind: .routine, label: "AC desk", symbol: "desktopcomputer", color: "#8FB4C4", target: "ac desk", enabled: false),
        Tile(id: "r-dressing", kind: .routine, label: "Dressing lights", symbol: "lightbulb.2.fill", color: "#FBBF24", target: "dressing lights", enabled: false),
        Tile(id: "r-music", kind: .routine, label: "Music", symbol: "music.note", color: "#EC4899", target: "Alexa, music", enabled: false),
    ]
}

// MARK: - App settings (app-settings.json)

struct DeckSettings: Codable {
    var speechEngine: String = "apple"       // apple | whisper | apple-then-whisper
    var speechLocale: String = "en-US"
    var whisperModelPath: String = "~/.local/share/whisper-models/ggml-large-v3-turbo.bin"
    var silenceSeconds: Double = 1.1
    var maxListenSeconds: Double = 12
    var hotkeyEnabled: Bool = true
    /// Letter for the ⌃⌥<key> push-to-talk chord. Space is macOS's input-source switcher, so avoid it.
    var hotkeyKey: String = "a"
    var hudCorner: String = "topCenter"
    var launchAtLogin: Bool = false
    var clickupToken: String = ""            // phase 2

    static func load() -> DeckSettings {
        guard let data = try? Data(contentsOf: DeckPaths.appSettings),
              let s = try? JSONDecoder().decode(DeckSettings.self, from: data) else { return DeckSettings() }
        return s
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) {
            try? FileManager.default.createDirectory(at: DeckPaths.dir, withIntermediateDirectories: true)
            try? d.write(to: DeckPaths.appSettings, options: .atomic)
        }
    }
}

extension DeckSettings {
    /// Tolerant decoding: a file missing newer keys (or one written by the suite installer with only
    /// a few keys) keeps the defaults for whatever is absent instead of throwing everything away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        speechEngine = try c.decodeIfPresent(String.self, forKey: .speechEngine) ?? speechEngine
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? speechLocale
        whisperModelPath = try c.decodeIfPresent(String.self, forKey: .whisperModelPath) ?? whisperModelPath
        silenceSeconds = try c.decodeIfPresent(Double.self, forKey: .silenceSeconds) ?? silenceSeconds
        maxListenSeconds = try c.decodeIfPresent(Double.self, forKey: .maxListenSeconds) ?? maxListenSeconds
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? hotkeyEnabled
        hotkeyKey = try c.decodeIfPresent(String.self, forKey: .hotkeyKey) ?? hotkeyKey
        hudCorner = try c.decodeIfPresent(String.self, forKey: .hudCorner) ?? hudCorner
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        clickupToken = try c.decodeIfPresent(String.self, forKey: .clickupToken) ?? clickupToken
    }
}
