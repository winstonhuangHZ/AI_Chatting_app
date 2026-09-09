import Foundation

/// A conversation consisting of an ordered list of messages.
struct ChatSession: Identifiable, Codable, Hashable {

    /// Stable identifier for this session.
    var id: UUID

    /// Display title shown in the sidebar.
    var title: String

    /// AI-chosen emoji shown before the title in the sidebar.
    var emoji: String?

    /// All messages in chronological order.
    var messages: [ChatMessage]

    /// When the session was created.
    var createdAt: Date

    /// `true` when this session is a dedicated personalization-collection chat (started
    /// via "添加个性化块"): it uses the collector system prompt and offers a
    /// "生成个性化块" action that turns the transcript into a named personalization block.
    var isPersonalizationCollection: Bool

    /// `true` once the model has chosen a title via `set_session_metadata`.
    /// Used to keep offering the title tool after the first round until the
    /// model actually gives the conversation a real label.
    var hasModelTitle: Bool

    /// `true` when the user pinned this conversation to the top of the sidebar.
    var isPinned: Bool

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        emoji: String? = nil,
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        isPersonalizationCollection: Bool = false,
        hasModelTitle: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.messages = messages
        self.createdAt = createdAt
        self.isPersonalizationCollection = isPersonalizationCollection
        self.hasModelTitle = hasModelTitle
        self.isPinned = isPinned
    }

    /// Derives a meaningful title from the first meaningful user message.
    mutating func autoTitle() {
        guard !hasModelTitle else { return }
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

    // MARK: - Codable
    //
    // Custom decode so sessions persisted before `emoji` / `isPersonalizationCollection`
    // existed still decode (decodeIfPresent → default), avoiding silent data loss
    // in the store's `try?` decode. `emoji` is omitted from JSON when nil.

    private enum CodingKeys: String, CodingKey {
        case id, title, emoji, messages, createdAt, isPersonalizationCollection, hasModelTitle, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isPersonalizationCollection = try container.decodeIfPresent(Bool.self, forKey: .isPersonalizationCollection) ?? false
        let decodedModelTitle = try container.decodeIfPresent(Bool.self, forKey: .hasModelTitle)
        // Old archives predate the flag: a session with an AI-chosen emoji was
        // almost certainly titled by the model too, so don't re-prompt for it.
        let inferredFromEmoji = emoji?.isEmpty == false
        hasModelTitle = decodedModelTitle ?? inferredFromEmoji
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(emoji, forKey: .emoji)
        try container.encode(messages, forKey: .messages)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isPersonalizationCollection, forKey: .isPersonalizationCollection)
        try container.encode(hasModelTitle, forKey: .hasModelTitle)
        try container.encode(isPinned, forKey: .isPinned)
    }
}
