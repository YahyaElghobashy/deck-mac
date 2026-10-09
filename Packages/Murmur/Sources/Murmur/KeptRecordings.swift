import Foundation

/// Recent dictation audio kept on this Mac for troubleshooting: the last 20 recordings, each
/// deleted after 24 hours, never sent anywhere. Each sits next to a .txt saying what Deck wrote and
/// how it decided (language probes, pieces), so a wrong dictation can be replayed through
/// `murmur stream` exactly as it was spoken. On by the user's choice (9 October 2026, after two
/// real dictations failed in ways the synthetic voices never showed); turning it off deletes them.
public enum KeptRecordings {
    public static let lifetime: TimeInterval = 24 * 3600
    public static let maxCount = 20
    /// Where they go; nil keeps nothing. Set by the app at launch.
    public static var directory: URL?

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Copies a finished recording in (the original is still deleted by its owner as before) and
    /// returns the copy. Prunes first.
    @discardableResult
    public static func keep(_ wav: URL, at date: Date = Date()) -> URL? {
        guard let dir = directory else { return nil }
        prune(now: date)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let dest = dir.appendingPathComponent(stamp.string(from: date) + ".wav")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: wav, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// The note next to a kept recording: what was written and how it was decided.
    public static func annotate(_ kept: URL?, _ lines: [String]) {
        guard let kept else { return }
        let note = kept.deletingPathExtension().appendingPathExtension("txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: note, atomically: true, encoding: .utf8)
    }

    /// Deletes recordings older than 24 hours and all but the newest `maxCount`.
    public static func prune(now: Date = Date()) {
        guard let dir = directory else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let wavs = names.filter { $0.hasSuffix(".wav") }.sorted(by: >)       // newest first (timestamp names)
        for (i, name) in wavs.enumerated() {
            let url = dir.appendingPathComponent(name)
            let made = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? .distantPast
            if i >= maxCount - 1 || now.timeIntervalSince(made) > lifetime { remove(url) }
        }
    }

    public static func removeAll() {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private static func remove(_ wav: URL) {
        try? FileManager.default.removeItem(at: wav)
        try? FileManager.default.removeItem(at: wav.deletingPathExtension().appendingPathExtension("txt"))
    }
}
