import Foundation

/// A user/AI-created folder used to group sidebar conversations.
struct ChatFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Opt-in folder-level sharing (nil/false = disabled).
    var sharedContextEnabled: Bool? = nil

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
