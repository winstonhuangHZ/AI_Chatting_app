import Foundation

/// The role a `ChatMessage` plays in a conversation.
///
/// Mirrors the OpenAI Chat Completions `role` field.
enum ChatMessageRole: String, Codable, Hashable {
    case system
    case user
    case assistant
}

/// A single message within a `ChatSession`.
///
/// Content is the fully accumulated text. When streaming, the assistant
/// message's content is updated incrementally as `delta` chunks arrive.
struct ChatMessage: Identifiable, Codable, Hashable {

    /// Stable identifier for this message.
    var id: UUID

    /// The speaker (user / assistant / system instruction).
    var role: ChatMessageRole

    /// Full message text.
    var content: String

    /// When the message was created.
    var timestamp: Date

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    /// Convenience factory for user messages.
    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    /// Convenience factory for assistant messages.
    static func assistant(_ content: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }

    /// Convenience factory for system messages.
    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: .system, content: content)
    }
}