import Foundation

/// Shared folder the app, the widget extension and the Node bridge all read/write.
enum DeckPaths {
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var dir: URL { realHome.appendingPathComponent("Library/Application Support/Deck", isDirectory: true) }
    static var alexaState: URL { dir.appendingPathComponent("alexa-state.json") }
    static var bridgeToken: URL { dir.appendingPathComponent("bridge-token") }
    static var bridgeConfig: URL { dir.appendingPathComponent("bridge-config.json") }
    static var actions: URL { dir.appendingPathComponent("actions.json") }
    static var appSettings: URL { dir.appendingPathComponent("app-settings.json") }
    static var trace: URL { dir.appendingPathComponent("deck-trace.log") }

    static let bridgePort = 47831
    static let urlScheme = "deck"
    static let widgetKind = "DeckAlexaWidget"
    static let listenNotification = Notification.Name("com.yahya.deck.listen")
    static let stateChangedNotification = Notification.Name("com.yahya.deck.stateChanged")
}

enum DebugLog {
    nonisolated static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(ProcessInfo.processInfo.processName)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = DeckPaths.trace
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 300_000 { try? FileManager.default.removeItem(at: url) }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
