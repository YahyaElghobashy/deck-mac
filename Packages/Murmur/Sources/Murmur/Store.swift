import Foundation
import SQLite3

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
}

/// A dictation as it is kept in the database.
public struct DictationRecord {
    public var text: String
    public var lang: String
    public var engine: String
    public var delivery: String
    public var appBundleID: String?
    public var audioSeconds: Double
    public var transcribeMs: Int
    public var createdAt: Date

    public init(text: String, lang: String, engine: String, delivery: String, appBundleID: String?,
                audioSeconds: Double, transcribeMs: Int, createdAt: Date = Date()) {
        self.text = text; self.lang = lang; self.engine = engine; self.delivery = delivery
        self.appBundleID = appBundleID; self.audioSeconds = audioSeconds; self.transcribeMs = transcribeMs
        self.createdAt = createdAt
    }
}

public struct SearchHit {
    public let kind: String
    public let refID: Int64
    public let snippet: String
}

/// Deck's local database: dictations, notes, meetings and settings in one SQLite file, with one
/// full-text index over all of them. Migrations run forward only, keyed on `PRAGMA user_version`,
/// each in its own transaction. Use from one thread at a time.
public final class Store {
    /// Index i holds the statements that take the schema from version i to i + 1. Append only.
    public static let migrations: [[String]] = [
        [
            """
            CREATE TABLE dictations(
              id INTEGER PRIMARY KEY, created_at REAL NOT NULL, text TEXT NOT NULL, lang TEXT,
              engine TEXT, delivery TEXT, app_bundle_id TEXT, audio_seconds REAL, transcribe_ms INTEGER)
            """,
            "CREATE INDEX dictations_created ON dictations(created_at)",
            """
            CREATE TABLE notes(
              id INTEGER PRIMARY KEY, created_at REAL NOT NULL, updated_at REAL NOT NULL,
              title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL, path TEXT)
            """,
            """
            CREATE TABLE meetings(
              id INTEGER PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL, title TEXT NOT NULL DEFAULT '',
              calendar_event_id TEXT, folder TEXT, summary TEXT NOT NULL DEFAULT '', transcript TEXT NOT NULL DEFAULT '')
            """,
            "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE VIRTUAL TABLE search USING fts5(kind UNINDEXED, ref_id UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2')",
            "CREATE TRIGGER dictations_ai AFTER INSERT ON dictations BEGIN INSERT INTO search(kind, ref_id, title, body) VALUES ('dictation', new.id, '', new.text); END",
            "CREATE TRIGGER dictations_ad AFTER DELETE ON dictations BEGIN DELETE FROM search WHERE kind = 'dictation' AND ref_id = old.id; END",
            "CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN INSERT INTO search(kind, ref_id, title, body) VALUES ('note', new.id, new.title, new.body); END",
            "CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN UPDATE search SET title = new.title, body = new.body WHERE kind = 'note' AND ref_id = new.id; END",
            "CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN DELETE FROM search WHERE kind = 'note' AND ref_id = old.id; END",
            "CREATE TRIGGER meetings_ai AFTER INSERT ON meetings BEGIN INSERT INTO search(kind, ref_id, title, body) VALUES ('meeting', new.id, new.title, new.summary || ' ' || new.transcript); END",
            "CREATE TRIGGER meetings_au AFTER UPDATE ON meetings BEGIN UPDATE search SET title = new.title, body = new.summary || ' ' || new.transcript WHERE kind = 'meeting' AND ref_id = new.id; END",
            "CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN DELETE FROM search WHERE kind = 'meeting' AND ref_id = old.id; END",
        ],
    ]

    public let url: URL
    private var db: OpaquePointer?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(db)
            throw StoreError(description: "cannot open \(url.path): \(message)")
        }
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode = WAL")
        try migrate()
    }

    deinit { sqlite3_close_v2(db) }

    public var schemaVersion: Int { (try? query("PRAGMA user_version") { Int(sqlite3_column_int($0, 0)) }.first) ?? 0 }

    private func migrate() throws {
        let from = schemaVersion
        guard from < Self.migrations.count else { return }
        for version in from..<Self.migrations.count {
            try exec("BEGIN IMMEDIATE")
            do {
                for sql in Self.migrations[version] { try exec(sql) }
                try exec("PRAGMA user_version = \(version + 1)")
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: Dictations

    @discardableResult
    public func addDictation(_ r: DictationRecord) throws -> Int64 {
        try run("""
            INSERT INTO dictations(created_at, text, lang, engine, delivery, app_bundle_id, audio_seconds, transcribe_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [r.createdAt.timeIntervalSince1970, r.text, r.lang, r.engine, r.delivery, r.appBundleID, r.audioSeconds, r.transcribeMs])
        return sqlite3_last_insert_rowid(db)
    }

    public func latestDictation() throws -> (text: String, at: Date)? {
        try query("SELECT text, created_at FROM dictations ORDER BY created_at DESC, id DESC LIMIT 1") {
            (String(cString: sqlite3_column_text($0, 0)), Date(timeIntervalSince1970: sqlite3_column_double($0, 1)))
        }.first
    }

    public func dictationCount() throws -> Int {
        try query("SELECT count(*) FROM dictations") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    // MARK: Search

    /// Every word must appear; the last one may be a prefix. Results come best match first.
    public func search(_ text: String, limit: Int = 20) throws -> [SearchHit] {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let match = words.enumerated().map { i, w in "\"\(w)\"" + (i == words.count - 1 ? "*" : "") }.joined(separator: " ")
        return try query("""
            SELECT kind, ref_id, snippet(search, 3, '[', ']', '…', 12) FROM search
            WHERE search MATCH ? ORDER BY rank LIMIT ?
            """, [match, limit]) {
            SearchHit(kind: String(cString: sqlite3_column_text($0, 0)), refID: sqlite3_column_int64($0, 1),
                      snippet: String(cString: sqlite3_column_text($0, 2)))
        }
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try query("SELECT value FROM settings WHERE key = ?", [key]) { String(cString: sqlite3_column_text($0, 0)) }.first
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try run("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    // MARK: SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw StoreError(description: "\(message) in: \(sql.prefix(80))")
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError(description: "\(String(cString: sqlite3_errmsg(db))) in: \(sql.prefix(80))")
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_finalize(stmt); throw StoreError(description: "unsupported value \(String(describing: arg))")
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [Any?] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError(description: String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ args: [Any?] = [], row: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(row(stmt)); continue }
            if rc == SQLITE_DONE { return out }
            throw StoreError(description: String(cString: sqlite3_errmsg(db)))
        }
    }
}
