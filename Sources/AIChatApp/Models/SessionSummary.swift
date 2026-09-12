import Foundation

/// Per-session summary used by folder shared-context tools.
struct SessionSummary: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        case fresh
        case stale
        case failed
    }

    var sessionID: UUID
    var summary: String
    var updatedAt: Date
    var coveredLastMessageID: UUID?
    var coveredMessageCount: Int
    var model: String?
    var status: Status

    var id: UUID { sessionID }
}
