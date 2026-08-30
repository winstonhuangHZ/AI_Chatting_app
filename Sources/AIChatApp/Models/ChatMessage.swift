import Foundation

/// The role a `ChatMessage` plays in a conversation.
///
/// Mirrors the OpenAI Chat Completions `role` field.
enum ChatMessageRole: String, Codable, Hashable {
    case system
    case user
    case assistant
}

/// A single image attachment embedded in a user message.
///
/// The image is stored as base64 data; the request body converts it to an
/// OpenAI-compatible `image_url` block:
/// `{"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}`
struct ImageAttachment: Identifiable, Codable, Hashable {

    /// Stable identifier for this attachment.
    var id: UUID

    /// Original file name (for display / saving).
    var filename: String

    /// MIME type, e.g. `image/png`, `image/jpeg`, `image/gif`, `image/webp`.
    var mimeType: String

    /// Base64-encoded image bytes (no `data:` prefix).
    var base64Data: String

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        base64Data: String
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64Data = base64Data
    }

    /// Full `data:` URI used in the API request.
    var dataURI: String {
        "data:\(mimeType);base64,\(base64Data)"
    }

    /// Decodes the base64 payload back into `Data` (for preview rendering).
    var decodedData: Data? {
        Data(base64Encoded: base64Data)
    }
}

/// A single document (PDF) attachment embedded in a user message.
///
/// The file bytes are stored base64-encoded; at request time the service
/// either renders its pages into vision-model images (`image_url` parts) or
/// extracts its text for text-only models.
struct DocumentAttachment: Identifiable, Codable, Hashable {

    /// Stable identifier for this attachment.
    var id: UUID

    /// Original file name (for display / saving).
    var filename: String

    /// MIME type, e.g. `application/pdf`.
    var mimeType: String

    /// Base64-encoded file bytes (no `data:` prefix).
    var base64Data: String

    /// Number of pages (computed at attach time; 0 when unknown).
    var pageCount: Int

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        base64Data: String,
        pageCount: Int = 0
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.pageCount = pageCount
    }

    /// Decodes the base64 payload back into `Data` (for preview / processing).
    var decodedData: Data? {
        Data(base64Encoded: base64Data)
    }
}

/// A clickable source reference (web_search / web_fetch result) attached to an
/// assistant reply in Agent mode. Rendered as a "Sources" card under the bubble.
struct ChatSource: Identifiable, Codable, Hashable {
    /// Display title (page title for search hits, host for fetched pages).
    var title: String

    /// Absolute http(s) URL.
    var url: String

    /// Identity = URL so duplicates collapse across tool calls.
    var id: String { url }
}

/// A single message within a `ChatSession`.
///
/// Content is the fully accumulated text. When streaming, the assistant
/// message's content is updated incrementally as `delta` chunks arrive.
/// User messages may carry image attachments for multimodal models.
struct ChatMessage: Identifiable, Codable, Hashable {

    /// Stable identifier for this message.
    var id: UUID

    /// The speaker (user / assistant / system instruction).
    var role: ChatMessageRole

    /// Full message text.
    var content: String

    /// Image attachments (user messages only; multimodal models).
    var attachments: [ImageAttachment]

    /// Document (PDF) attachments (user messages only).
    var documentAttachments: [DocumentAttachment]

    /// When the message was created.
    var timestamp: Date

    /// Source references (web tools) rendered below assistant replies.
    var sources: [ChatSource]

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        attachments: [ImageAttachment] = [],
        documentAttachments: [DocumentAttachment] = [],
        timestamp: Date = Date(),
        sources: [ChatSource] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.documentAttachments = documentAttachments
        self.timestamp = timestamp
        self.sources = sources
    }

    /// Convenience factory for user messages (with optional image attachments).
    static func user(
        _ content: String,
        attachments: [ImageAttachment] = [],
        documents: [DocumentAttachment] = []
    ) -> ChatMessage {
        ChatMessage(
            role: .user,
            content: content,
            attachments: attachments,
            documentAttachments: documents
        )
    }

    /// Convenience factory for assistant messages.
    static func assistant(_ content: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }

    /// Convenience factory for system messages.
    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: .system, content: content)
    }

    // MARK: - Codable

    /// Custom decoding so messages persisted *before* multimodal support
    /// (without an `attachments` key) still decode correctly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([ImageAttachment].self, forKey: .attachments) ?? []
        documentAttachments = try container.decodeIfPresent([DocumentAttachment].self, forKey: .documentAttachments) ?? []
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sources = try container.decodeIfPresent([ChatSource].self, forKey: .sources) ?? []
    }
}
