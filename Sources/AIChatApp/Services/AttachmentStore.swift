import Foundation

/// Stores message attachments as files under Application Support instead of
/// embedding base64 in the session database.
enum AttachmentStore {

    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base
            .appendingPathComponent("AIChatApp", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes bytes to disk and returns the path relative to Application
    /// Support/AIChatApp (e.g. "Attachments/<uuid>.png").
    static func store(_ data: Data, id: UUID, filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        let name = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        do {
            let url = try directory().appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return "Attachments/\(name)"
        } catch {
            return nil
        }
    }

    static func load(_ relativePath: String) -> Data? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let url = base
            .appendingPathComponent("AIChatApp", isDirectory: true)
            .appendingPathComponent(relativePath)
        return try? Data(contentsOf: url)
    }

    static func delete(_ relativePath: String) {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let url = base
            .appendingPathComponent("AIChatApp", isDirectory: true)
            .appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }
}
