import Foundation

/// A conversation consisting of an ordered list of messages.
struct ChatSession: Identifiable, Codable, Hashable {

    /// Stable identifier for this session.
    var id: UUID

    /// Display title shown in the sidebar.
    var title: String

    /// All messages in chronological order.
    var messages: [ChatMessage]

    /// When the session was created.
    var createdAt: Date

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        messages: [ChatMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
    }

    /// Derives a meaningful title from the first meaningful user message.
    mutating func autoTitle() {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || title == "New Chat" else {
            return
        }

        for message in messages where message.role == .user {
            let cleaned = message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.isEmpty else { continue }

            // Keep it short enough for a sidebar label.
            let maxLength = 24
            title = cleaned.count > maxLength
                ? String(cleaned.prefix(maxLength)) + "…"
                : cleaned
            return
        }
    }
}