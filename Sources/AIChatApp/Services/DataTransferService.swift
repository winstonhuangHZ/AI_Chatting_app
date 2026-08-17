import Foundation
import AppKit
import SQLite3

// MARK: - 数据备份/恢复服务
//
// 支持两种格式：
//   - ZIP：manifest.json + 各 JSON 文件（沿用原实现）
//   - SQLite：单个 .sqlite 数据库文件（sessions/messages/api_profiles/user_preferences 表）
// 导出/导入时由用户选择格式。

/// 备份格式。
enum BackupFormat: String, CaseIterable, Identifiable {
    case zip
    case sqlite

    var id: String { rawValue }

    /// 文件扩展名。
    var fileExtension: String {
        switch self {
        case .zip:   return "zip"
        case .sqlite: return "sqlite"
        }
    }

    /// 界面显示名（本地化；缺 key 回退英文）。
    var displayName: String {
        switch self {
        case .zip:    return L("backup.format.zip")
        case .sqlite: return L("backup.format.sqlite")
        }
    }
}

/// 备份文件结构说明（ZIP 兼容的 Bundle）。
struct BackupBundle: Codable {
    /// 备份格式版本。
    static let currentVersion = 1

    /// 导出时间（ISO8601）。
    var exportedAt: Date

    /// 会话历史。
    var chatSessions: [ChatSession]

    /// API 配置。
    var apiProfiles: [APIServerConfig]

    /// 用户画像偏好。
    var userPreferences: [UserPreference]

    /// 外观设置（字体/字号）。
    var appearance: BackupAppearance?

    /// 应用界面语言（可选）。
    var appLanguage: String?
}

/// 外观设置的备份格式。
struct BackupAppearance: Codable {
    var fontPreset: String
    var fontSizeLevel: Int
}

/// 数据导出/导入服务（纯 Foundation，无第三方依赖）。
enum DataTransferService {

    // MARK: - 导出（格式选择）

    /// 弹出保存面板并按所选格式导出一个备份文件。
    static func exportToFile(
        format: BackupFormat,
        sessions: [ChatSession],
        profiles: [APIServerConfig],
        preferences: [UserPreference],
        appearance: AppearanceStore,
        language: String?
    ) throws -> URL {
        let panel = NSSavePanel()
        panel.title = L("backup.export")
        panel.prompt = L("backup.export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "AIChatBackup-\(Self.dateStamp()).\(format.fileExtension)"
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK, let url = panel.url else {
            throw BackupError.cancelled
        }

        switch format {
        case .zip:
            let data = try export(
                sessions: sessions,
                profiles: profiles,
                preferences: preferences,
                appearance: appearance,
                language: language
            )
            try data.write(to: url)
        case .sqlite:
            try exportSQLite(
                to: url,
                sessions: sessions,
                profiles: profiles,
                preferences: preferences,
                appearance: appearance,
                language: language
            )
        }
        return url
    }

    // MARK: - ZIP 导出

    /// 生成备份 zip 的 Data（包含一个 manifest.json + 目录内 JSON 文件）。
    static func export(
        sessions: [ChatSession],
        profiles: [APIServerConfig],
        preferences: [UserPreference],
        appearance: AppearanceStore,
        language: String?
    ) throws -> Data {
        let backup = BackupBundle(
            exportedAt: Date(),
            chatSessions: sessions,
            apiProfiles: profiles,
            userPreferences: preferences,
            appearance: BackupAppearance(
                fontPreset: appearance.fontPreset.rawValue,
                fontSizeLevel: appearance.fontSizeLevel.rawValue
            ),
            appLanguage: language
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // 生成各 JSON 文件的内容。
        let manifestData = try encoder.encode(backup)
        let sessionsData = try encoder.encode(sessions)
        let profilesData = try encoder.encode(profiles)
        let prefsData = try encoder.encode(preferences)

        // 用 FileManager 写临时目录 → 用 /usr/bin/zip 打包 → 读出 Data → 清理。
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChatBackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let sessionsURL = tempDir.appendingPathComponent("chat_sessions.json")
        let profilesURL = tempDir.appendingPathComponent("api_profiles.json")
        let prefsURL = tempDir.appendingPathComponent("user_profile.json")

        try manifestData.write(to: manifestURL)
        try sessionsData.write(to: sessionsURL)
        try profilesData.write(to: profilesURL)
        try prefsData.write(to: prefsURL)

        // 调用系统 zip（可靠且零依赖）。
        let zipURL = tempDir.appendingPathComponent("backup.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-j", zipURL.path,
                             manifestURL.path,
                             sessionsURL.path,
                             profilesURL.path,
                             prefsURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BackupError.zipFailed
        }

        return try Data(contentsOf: zipURL)
    }

    // MARK: - SQLite 导出

    /// 将全部数据写入一个 SQLite 数据库文件。
    static func exportSQLite(
        to url: URL,
        sessions: [ChatSession],
        profiles: [APIServerConfig],
        preferences: [UserPreference],
        appearance: AppearanceStore,
        language: String?
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw BackupError.sqliteFailed
        }
        defer { sqlite3_close(db) }

        let sqlStatements = [
            // 建表
            "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);",
            "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, title TEXT, created_at REAL);",
            "CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, attachments TEXT, timestamp REAL);",
            "CREATE TABLE IF NOT EXISTS api_profiles (id TEXT PRIMARY KEY, json TEXT);",
            "CREATE TABLE IF NOT EXISTS user_preferences (id TEXT PRIMARY KEY, json TEXT);",
            // meta
            "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', '1');"
        ]
        for stmt in sqlStatements {
            guard sqlite3_exec(db, stmt, nil, nil, nil) == SQLITE_OK else {
                throw BackupError.sqliteFailed
            }
        }

        // 会话 & 消息
        for session in sessions {
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            _ = insertRun(sql: "INSERT OR REPLACE INTO sessions(id, title, created_at) VALUES(?, ?, ?);",
                          bind: { stmt in
                sqlite3_bind_text(stmt, 1, (session.id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (session.title as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 3, session.createdAt.timeIntervalSince1970)
            }, db: db)
            for message in session.messages {
                _ = insertRun(sql: "INSERT OR REPLACE INTO messages(id, session_id, role, content, attachments, timestamp) VALUES(?, ?, ?, ?, ?, ?);",
                              bind: { stmt in
                    sqlite3_bind_text(stmt, 1, (message.id.uuidString as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (session.id.uuidString as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, (message.role.rawValue as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (message.content as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 5, (Self.jsonString(from: message.attachments) as NSString?)?.utf8String, -1, nil)
                    sqlite3_bind_double(stmt, 6, message.timestamp.timeIntervalSince1970)
                }, db: db)
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }

        // API profiles（每行存完整 JSON，便于恢复）。
        for profile in profiles {
            let profileJSON = (try? Self.jsonObjectString(profile)) ?? ""
            _ = insertRun(sql: "INSERT OR REPLACE INTO api_profiles(id, json) VALUES(?, ?);",
                          bind: { stmt in
                sqlite3_bind_text(stmt, 1, (profile.id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (profileJSON as NSString).utf8String, -1, nil)
            }, db: db)
        }

        // 用户偏好
        for pref in preferences {
            let prefJSON = (try? Self.jsonObjectString(pref)) ?? ""
            _ = insertRun(sql: "INSERT OR REPLACE INTO user_preferences(id, json) VALUES(?, ?);",
                          bind: { stmt in
                sqlite3_bind_text(stmt, 1, (pref.id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (prefJSON as NSString).utf8String, -1, nil)
            }, db: db)
        }

        // 外观 / 语言
        if let appearanceJSON = try? JSONEncoder().encode(BackupAppearance(fontPreset: appearance.fontPreset.rawValue, fontSizeLevel: appearance.fontSizeLevel.rawValue)),
           let appearanceStr = String(data: appearanceJSON, encoding: .utf8) {
            _ = insertRun(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('appearance', ?);",
                          bind: { stmt in
                sqlite3_bind_text(stmt, 1, (appearanceStr as NSString).utf8String, -1, nil)
            }, db: db)
        }
        if let language {
            _ = insertRun(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('language', ?);",
                          bind: { stmt in
                sqlite3_bind_text(stmt, 1, (language as NSString).utf8String, -1, nil)
            }, db: db)
        }
    }

    // MARK: - 导入（自动识别格式）

    /// 弹出打开面板，选择 zip 或 sqlite 备份，自动按扩展名识别解析。
    static func importFromFile() throws -> BackupBundle {
        // 先弹出格式选择（在 BackupRestoreView 已做），这里直接打开面板。
        let panel = NSOpenPanel()
        panel.title = L("backup.import")
        panel.prompt = L("backup.import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK, let url = panel.url else {
            throw BackupError.cancelled
        }

        switch url.pathExtension.lowercased() {
        case BackupFormat.sqlite.fileExtension, "db", "sqlite3":
            return try importSQLite(from: url)
        default:
            return try importFromZIP(url: url)
        }
    }

    /// 解析特定 URL 的备份（按扩展名自动识别）。
    static func importFrom(url: URL) throws -> BackupBundle {
        switch url.pathExtension.lowercased() {
        case BackupFormat.sqlite.fileExtension, "db", "sqlite3":
            return try importSQLite(from: url)
        default:
            return try importFromZIP(url: url)
        }
    }

    /// 解析 zip 备份文件。
    static func importFromZIP(url: URL) throws -> BackupBundle {
        // 解压到临时目录（系统 unzip）。
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChatRestore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BackupError.unzipFailed
        }

        // 读取 manifest.json。
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BackupError.invalidFormat
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(BackupBundle.self, from: data)
    }

    /// 解析 SQLite 备份文件。
    static func importSQLite(from url: URL) throws -> BackupBundle {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.invalidFormat
        }

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw BackupError.sqliteFailed
        }
        defer { sqlite3_close(db) }

        // 读取 meta
        var meta: [String: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT key, value FROM meta;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                    meta[String(cString: k)] = String(cString: v)
                }
            }
        }
        sqlite3_finalize(stmt)

        // 读取 sessions
        var sessions: [ChatSession] = []
        var sessionMap: [String: ChatSession] = [:]

        // 先建空 session 骨架
        if sqlite3_prepare_v2(db, "SELECT id, title, created_at FROM sessions;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Chat"
                let ts = sqlite3_column_double(stmt, 2)
                guard let uuid = UUID(uuidString: id) else { continue }
                let session = ChatSession(id: uuid, title: title, messages: [], createdAt: Date(timeIntervalSince1970: ts))
                sessionMap[id] = session
            }
        }
        sqlite3_finalize(stmt)

        // 读取 messages 并挂到 session
        if sqlite3_prepare_v2(db, "SELECT id, session_id, role, content, attachments, timestamp FROM messages ORDER BY timestamp;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let msgID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let sessionID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let role = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "user"
                let content = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let attachmentsStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let ts = sqlite3_column_double(stmt, 5)

                guard let uID = UUID(uuidString: msgID),
                      UUID(uuidString: sessionID) != nil,
                      var session = sessionMap[sessionID],
                      let roleEnum = ChatMessageRole(rawValue: role) else { continue }
                let attachments: [ImageAttachment] = (try? JSONDecoder().decode([ImageAttachment].self, from: Data(attachmentsStr.utf8))) ?? []
                session.messages.append(ChatMessage(id: uID, role: roleEnum, content: content, attachments: attachments, timestamp: Date(timeIntervalSince1970: ts)))
                sessionMap[sessionID] = session
            }
        }
        sqlite3_finalize(stmt)

        // 读取 API profiles
        var profiles: [APIServerConfig] = []
        if sqlite3_prepare_v2(db, "SELECT json FROM api_profiles;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let json = sqlite3_column_text(stmt, 0) {
                    let str = String(cString: json)
                    if let data = str.data(using: .utf8),
                       let profile = try? JSONDecoder().decode(APIServerConfig.self, from: data) {
                        profiles.append(profile)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)

        // 读取 user preferences
        var prefs: [UserPreference] = []
        if sqlite3_prepare_v2(db, "SELECT json FROM user_preferences;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let json = sqlite3_column_text(stmt, 0) {
                    let str = String(cString: json)
                    if let data = str.data(using: .utf8),
                       let pref = try? JSONDecoder().decode(UserPreference.self, from: data) {
                        prefs.append(pref)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)

        // 外观 / 语言
        var backupAppearance: BackupAppearance?
        if let appearanceJSON = meta["appearance"], let data = appearanceJSON.data(using: .utf8) {
            backupAppearance = try? JSONDecoder().decode(BackupAppearance.self, from: data)
        }

        sessions = Array(sessionMap.values).sorted { $0.createdAt > $1.createdAt }

        return BackupBundle(
            exportedAt: Date(),
            chatSessions: sessions,
            apiProfiles: profiles,
            userPreferences: prefs,
            appearance: backupAppearance,
            appLanguage: meta["language"]
        )
    }

    // MARK: - 辅助

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func jsonString(from value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func jsonObjectString(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 执行一条带 bind 的 SQL（bind 闭包中逐字段绑定）。
    private static func insertRun(
        sql: String,
        bind: (OpaquePointer) -> Void,
        db: OpaquePointer?
    ) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE
    }
}

// MARK: - 错误类型

enum BackupError: LocalizedError {
    case cancelled
    case zipFailed
    case unzipFailed
    case invalidFormat
    case sqliteFailed

    var errorDescription: String? {
        switch self {
        case .cancelled:     return "Operation cancelled."
        case .zipFailed:     return "Failed to create the backup archive."
        case .unzipFailed:   return "Failed to extract the backup archive."
        case .invalidFormat: return "The selected file is not a valid AIChat backup."
        case .sqliteFailed:  return "Failed to read/write the SQLite backup file."
        }
    }
}