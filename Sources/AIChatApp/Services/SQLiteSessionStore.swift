import Foundation
import SQLite3

/// Phase-1 SQLite persistence for chat sessions.
///
/// The app still keeps `[ChatSession]` in memory (so the whole UI keeps
/// working), but persistence is now a transactional snapshot into
/// Application Support instead of a 40 MB UserDefaults rewrite.
///
/// Schema is deliberately hybrid: a small indexed core plus a JSON payload per
/// row, so all current `Codable` fields survive without a lossy mapping. Later
/// phases can normalise more columns and add FTS5.
final class SQLiteSessionStore {

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// `~/Library/Application Support/AIChatApp/aichat.sqlite`
    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("AIChatApp", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aichat.sqlite")
    }

    init(url: URL) throws {
        guard sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, db != nil else {
            throw SQLiteSessionStoreError.openFailed
        }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            json TEXT NOT NULL,
            sort_index INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            json TEXT NOT NULL,
            sort_index INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_session
            ON messages(session_id, sort_index);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Load

    func loadAll() -> [ChatSession] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        var metas: [(ChatSessionMeta, Int)] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT json, sort_index FROM sessions ORDER BY sort_index;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cString = sqlite3_column_text(statement, 0) else { continue }
                let json = String(cString: cString)
                let order = Int(sqlite3_column_int64(statement, 1))
                if let data = json.data(using: .utf8),
                   let meta = try? JSONDecoder().decode(ChatSessionMeta.self, from: data) {
                    metas.append((meta, order))
                }
            }
        }
        sqlite3_finalize(statement)
        guard !metas.isEmpty else { return [] }

        var messagesBySession: [UUID: [ChatMessage]] = [:]
        statement = nil
        if sqlite3_prepare_v2(db, "SELECT session_id, json FROM messages ORDER BY session_id, sort_index;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let jsonText = sqlite3_column_text(statement, 1),
                      let sessionID = UUID(uuidString: String(cString: idText)),
                      let data = String(cString: jsonText).data(using: .utf8),
                      let message = try? JSONDecoder().decode(ChatMessage.self, from: data) else { continue }
                messagesBySession[sessionID, default: []].append(message)
            }
        }
        sqlite3_finalize(statement)

        return metas
            .sorted { $0.1 < $1.1 }
            .map { meta, _ in
                meta.makeSession(messages: messagesBySession[meta.id] ?? [])
            }
    }

    // MARK: - Snapshot write

    @discardableResult
    func replaceAll(_ sessions: [ChatSession]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return false }

        do {
            try exec("BEGIN IMMEDIATE;")
            try exec("DELETE FROM messages;")
            try exec("DELETE FROM sessions;")
            for (sessionIndex, session) in sessions.enumerated() {
                let meta = ChatSessionMeta(session)
                let json = try JSONEncoder().encode(meta)
                let text = String(decoding: json, as: UTF8.self)
                try insert(
                    "INSERT INTO sessions(id, json, sort_index) VALUES(?, ?, ?);",
                    texts: [session.id.uuidString, text],
                    ints: [sessionIndex]
                )
                for (messageIndex, message) in session.messages.enumerated() {
                    let messageJSON = try JSONEncoder().encode(message)
                    try insert(
                        "INSERT INTO messages(id, session_id, json, sort_index) VALUES(?, ?, ?, ?);",
                        texts: [message.id.uuidString, session.id.uuidString, String(decoding: messageJSON, as: UTF8.self)],
                        ints: [messageIndex]
                    )
                }
            }
            try exec("COMMIT;")
            return true
        } catch {
            _ = try? exec("ROLLBACK;")
            return false
        }
    }

    func isEmpty() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return true }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sessions;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return true }
        return sqlite3_column_int64(statement, 0) == 0
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteSessionStoreError.execFailed
        }
    }

    private func insert(_ sql: String, texts: [String], ints: [Int]) throws {
        guard let db else { throw SQLiteSessionStoreError.execFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteSessionStoreError.execFailed
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for text in texts {
            sqlite3_bind_text(statement, bindIndex, (text as NSString).utf8String, -1, Self.transient)
            bindIndex += 1
        }
        for value in ints {
            sqlite3_bind_int64(statement, bindIndex, Int64(value))
            bindIndex += 1
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteSessionStoreError.execFailed
        }
    }
}

enum SQLiteSessionStoreError: Error {
    case openFailed
    case execFailed
}

/// Lightweight session row payload (messages live in their own table).
private struct ChatSessionMeta: Codable {
    var id: UUID
    var title: String
    var emoji: String?
    var createdAt: Date
    var isPersonalizationCollection: Bool
    var hasModelTitle: Bool
    var isPinned: Bool
    var folderID: UUID?

    init(_ session: ChatSession) {
        id = session.id
        title = session.title
        emoji = session.emoji
        createdAt = session.createdAt
        isPersonalizationCollection = session.isPersonalizationCollection
        hasModelTitle = session.hasModelTitle
        isPinned = session.isPinned
        folderID = session.folderID
    }

    func makeSession(messages: [ChatMessage]) -> ChatSession {
        ChatSession(
            id: id,
            title: title,
            emoji: emoji,
            messages: messages,
            createdAt: createdAt,
            isPersonalizationCollection: isPersonalizationCollection,
            hasModelTitle: hasModelTitle,
            isPinned: isPinned,
            folderID: folderID
        )
    }
}
