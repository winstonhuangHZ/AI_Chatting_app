import Foundation
import AppKit

// MARK: - 数据备份/恢复服务
//
// 一键导出全部用户数据为 zip（内含 JSON 文件），
// 一键导入该 zip 恢复到新环境。
//
// 导出内容：
//   - chat_sessions.json        聊天历史（ChatSession 数组）
//   - api_profiles.json         API 中转站配置（APIServerConfig 数组）
//   - user_profile.json         用户画像（UserPreference 数组）
//   - appearance.json           外观设置（字体预设/字号）
//   - app_language.json         界面语言（可选）

/// 备份文件结构说明（zip 内）。
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

    // MARK: - 导出

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
        process.arguments = ["-r", "-j", zipURL.path, tempDir.path]
        // 只打包本目录的 JSON 文件（-j 去目录，避免把 backup.zip 自己打进去）。
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

    /// 弹出保存面板，导出一个备份 zip 文件。
    static func exportToFile(
        sessions: [ChatSession],
        profiles: [APIServerConfig],
        preferences: [UserPreference],
        appearance: AppearanceStore,
        language: String?
    ) throws -> URL {
        let data = try export(
            sessions: sessions,
            profiles: profiles,
            preferences: preferences,
            appearance: appearance,
            language: language
        )

        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Export Backup", comment: "")
        panel.prompt = NSLocalizedString("Export", comment: "")
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "AIChatBackup-\(Self.dateStamp()).zip"

        guard panel.runModal() == .OK, let url = panel.url else {
            throw BackupError.cancelled
        }

        try data.write(to: url)
        return url
    }

    // MARK: - 导入

    /// 弹出打开面板，选择 zip 备份，返回解析后的 BackupBundle。
    static func importFromFile() throws -> BackupBundle {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Import Backup", comment: "")
        panel.prompt = NSLocalizedString("Import", comment: "")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            throw BackupError.cancelled
        }

        return try importFrom(url: url)
    }

    /// 解析 zip 备份文件。
    static func importFrom(url: URL) throws -> BackupBundle {
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

    // MARK: - 辅助

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - 错误类型

enum BackupError: LocalizedError {
    case cancelled
    case zipFailed
    case unzipFailed
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .cancelled:    return "Operation cancelled."
        case .zipFailed:    return "Failed to create the backup archive."
        case .unzipFailed:  return "Failed to extract the backup archive."
        case .invalidFormat: return "The selected file is not a valid AIChat backup."
        }
    }
}