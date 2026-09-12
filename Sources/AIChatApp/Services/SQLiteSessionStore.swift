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
    private(set) var ftsEnabled = false

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
        CREATE TABLE IF NOT EXISTS session_summaries (
            session_id TEXT PRIMARY KEY,
            json TEXT NOT NULL
        );
        """)
        // Trigram tokenizer keeps the previous substring-search semantics for
        // both Latin and CJK text.
        do {
            try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                content,
                message_id UNINDEXED,
                session_id UNINDEXED,
                tokenize = 'trigram'
            );
            """)
            ftsEnabled = true
        } catch {
            ftsEnabled = false
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Load

    func loadAll() -> [ChatSession] {
        let metas = loadSessionMetas()
        guard !metas.isEmpty else { return [] }
        return metas.map { meta in
            var session = meta
            session.messages = loadMessages(sessionID: meta.id)
            return session
        }
    }

    /// Metadata-only load: no message bodies. Used by the lazy/paged session
    /// store so startup does not pull the whole history into memory.
    func loadSessionMetas() -> [ChatSession] {
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

        // One grouped query gives every session its message count.
        var counts: [UUID: Int] = [:]
        statement = nil
        if sqlite3_prepare_v2(db, "SELECT session_id, COUNT(*) FROM messages GROUP BY session_id;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let sessionID = UUID(uuidString: String(cString: idText)) else { continue }
                counts[sessionID] = Int(sqlite3_column_int64(statement, 1))
            }
        }
        sqlite3_finalize(statement)

        return metas
            .sorted { $0.1 < $1.1 }
            .map { meta, _ in
                var session = meta.makeSession(messages: [])
                session.messageCount = counts[meta.id] ?? 0
                session.messagesLoaded = false
                return session
            }
    }

    /// Loads message bodies for one session. `limit`/`beforeSortIndex` page
    /// older messages; nil limit loads everything (the current default).
    func loadMessages(
        sessionID: UUID,
        limit: Int? = nil,
        beforeSortIndex: Int? = nil
    ) -> [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        var sql = "SELECT json FROM messages WHERE session_id = ?"
        var binds = 1
        if beforeSortIndex != nil {
            sql += " AND sort_index < ?"
            binds += 1
        }
        if let limit {
            sql += " ORDER BY sort_index DESC LIMIT \(max(1, limit))"
        } else {
            sql += " ORDER BY sort_index ASC"
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(statement, 1, (sessionID.uuidString as NSString).utf8String, -1, Self.transient)
        if let beforeSortIndex {
            sqlite3_bind_int64(statement, 2, Int64(beforeSortIndex))
        }

        var messages: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let jsonText = sqlite3_column_text(statement, 0),
                  let data = String(cString: jsonText).data(using: .utf8),
                  let message = try? JSONDecoder().decode(ChatMessage.self, from: data) else { continue }
            messages.append(message)
        }
        if limit != nil { messages.reverse() }
        return messages
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
            if ftsEnabled { try exec("DELETE FROM messages_fts;") }
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
                    if ftsEnabled {
                        try insert(
                            "INSERT INTO messages_fts(content, message_id, session_id) VALUES(?, ?, ?);",
                            texts: [message.content, message.id.uuidString, session.id.uuidString],
                            ints: []
                        )
                    }
                }
            }
            try exec("COMMIT;")
            // Keep the WAL from growing to a full second copy of the database
            // after large imports/migrations.
            _ = try? exec("PRAGMA wal_checkpoint(PASSIVE);")
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

    // MARK: - Row-level writes (phase 1.5)

    func upsertSession(_ session: ChatSession, order: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil,
              let json = try? JSONEncoder().encode(ChatSessionMeta(session)) else { return }
        _ = try? insert(
            "INSERT OR REPLACE INTO sessions(id, json, sort_index) VALUES(?, ?, ?);",
            texts: [session.id.uuidString, String(decoding: json, as: UTF8.self)],
            ints: [order]
        )
    }

    func upsertMessage(_ message: ChatMessage, sessionID: UUID, order: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil,
              let json = try? JSONEncoder().encode(message) else { return }
        _ = try? insert(
            "INSERT OR REPLACE INTO messages(id, session_id, json, sort_index) VALUES(?, ?, ?, ?);",
            texts: [message.id.uuidString, sessionID.uuidString, String(decoding: json, as: UTF8.self)],
            ints: [order]
        )
        indexMessage(id: message.id, sessionID: sessionID, content: message.content)
    }

    func deleteMessage(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        _ = try? insert(
            "DELETE FROM messages WHERE id = ?;",
            texts: [id.uuidString],
            ints: []
        )
        if ftsEnabled {
            _ = try? insert(
                "DELETE FROM messages_fts WHERE message_id = ?;",
                texts: [id.uuidString],
                ints: []
            )
        }
    }

    func deleteSession(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return }
        _ = try? exec("BEGIN IMMEDIATE;")
        _ = try? insert("DELETE FROM messages WHERE session_id = ?;", texts: [id.uuidString], ints: [])
        _ = try? insert("DELETE FROM sessions WHERE id = ?;", texts: [id.uuidString], ints: [])
        if ftsEnabled {
            _ = try? insert("DELETE FROM messages_fts WHERE session_id = ?;", texts: [id.uuidString], ints: [])
        }
        _ = try? exec("COMMIT;")
    }

    func deleteAll() {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return }
        _ = try? exec("BEGIN IMMEDIATE;")
        _ = try? exec("DELETE FROM messages;")
        _ = try? exec("DELETE FROM sessions;")
        if ftsEnabled { _ = try? exec("DELETE FROM messages_fts;") }
        _ = try? exec("COMMIT;")
    }

    func replaceMessages(sessionID: UUID, messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return }
        _ = try? exec("BEGIN IMMEDIATE;")
        _ = try? insert(
            "DELETE FROM messages WHERE session_id = ?;",
            texts: [sessionID.uuidString],
            ints: []
        )
        if ftsEnabled {
            _ = try? insert("DELETE FROM messages_fts WHERE session_id = ?;", texts: [sessionID.uuidString], ints: [])
        }
        for (index, message) in messages.enumerated() {
            if let json = try? JSONEncoder().encode(message) {
                _ = try? insert(
                    "INSERT OR REPLACE INTO messages(id, session_id, json, sort_index) VALUES(?, ?, ?, ?);",
                    texts: [message.id.uuidString, sessionID.uuidString, String(decoding: json, as: UTF8.self)],
                    ints: [index]
                )
                indexMessage(id: message.id, sessionID: sessionID, content: message.content)
            }
        }
        _ = try? exec("COMMIT;")
    }

    /// Merge the WAL back into the main database file.
    func checkpoint() {
        lock.lock()
        defer { lock.unlock() }
        _ = try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Session summaries

    func loadSummaries() -> [SessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT json FROM session_summaries;", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var result: [SessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let jsonText = sqlite3_column_text(statement, 0),
                  let data = String(cString: jsonText).data(using: .utf8),
                  let summary = try? JSONDecoder().decode(SessionSummary.self, from: data) else { continue }
            result.append(summary)
        }
        return result
    }

    func saveSummary(_ summary: SessionSummary) {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil,
              let data = try? JSONEncoder().encode(summary) else { return }
        _ = try? insert(
            "INSERT OR REPLACE INTO session_summaries(session_id, json) VALUES(?, ?);",
            texts: [summary.sessionID.uuidString, String(decoding: data, as: UTF8.self)],
            ints: []
        )
    }

    func deleteSummary(sessionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        _ = try? insert(
            "DELETE FROM session_summaries WHERE session_id = ?;",
            texts: [sessionID.uuidString],
            ints: []
        )
    }

    // MARK: - Full-text search

    /// Returns matching (messageID, sessionID) pairs ordered by relevance.
    /// Nil means FTS is unavailable and the caller should fall back.
    func searchMessageIDs(query: String, limit: Int) -> [(UUID, UUID)]? {
        guard ftsEnabled else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")

        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT message_id, session_id FROM messages_fts WHERE messages_fts MATCH ? ORDER BY bm25(messages_fts) LIMIT ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, ("\"\(escaped)\"" as NSString).utf8String, -1, Self.transient)
        sqlite3_bind_int64(statement, 2, Int64(limit))

        var hits: [(UUID, UUID)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let sessionText = sqlite3_column_text(statement, 1),
                  let messageID = UUID(uuidString: String(cString: idText)),
                  let sessionID = UUID(uuidString: String(cString: sessionText)) else { continue }
            hits.append((messageID, sessionID))
        }
        return hits
    }

    /// Rebuilds the FTS index from the message rows and reclaims free pages.
    func rebuildIndexAndCompact() {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil, ftsEnabled else { return }
        _ = try? exec("BEGIN IMMEDIATE;")
        _ = try? exec("DELETE FROM messages_fts;")
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, session_id, json FROM messages;", -1, &statement, nil) == SQLITE_OK {
            var rows: [(String, String, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let sessionText = sqlite3_column_text(statement, 1),
                      let jsonText = sqlite3_column_text(statement, 2) else { continue }
                rows.append((String(cString: idText), String(cString: sessionText), String(cString: jsonText)))
            }
            sqlite3_finalize(statement)
            for (id, sessionID, json) in rows {
                guard let data = json.data(using: .utf8),
                      let message = try? JSONDecoder().decode(ChatMessage.self, from: data) else { continue }
                if ftsEnabled {
                    _ = try? insert(
                        "INSERT INTO messages_fts(content, message_id, session_id) VALUES(?, ?, ?);",
                        texts: [message.content, id, sessionID],
                        ints: []
                    )
                }
            }
        } else {
            sqlite3_finalize(statement)
        }
        _ = try? exec("COMMIT;")
        _ = try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
        _ = try? exec("VACUUM;")
    }

    private func indexMessage(id: UUID, sessionID: UUID, content: String) {
        guard ftsEnabled else { return }
        _ = try? insert(
            "DELETE FROM messages_fts WHERE message_id = ?;",
            texts: [id.uuidString],
            ints: []
        )
        _ = try? insert(
            "INSERT INTO messages_fts(content, message_id, session_id) VALUES(?, ?, ?);",
            texts: [content, id.uuidString, sessionID.uuidString],
            ints: []
        )
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
