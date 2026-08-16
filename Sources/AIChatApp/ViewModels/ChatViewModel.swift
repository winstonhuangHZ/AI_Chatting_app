import Foundation
import Combine

/// Drives the active chat session: sending messages, consuming the SSE
/// stream, and accumulating response tokens into the assistant message.
///
/// Uses the callback-based `OpenAIService` (no async/await) so it compiles
/// with older SDKs. All network callbacks arrive on the main queue.
///
/// IMPORTANT: Sidebar selection is driven by `activeSessionID` only.
/// There are NO Combine sinks that write back to `activeSessionID`, which
/// would cause an infinite feedback loop and stack overflow.
final class ChatViewModel: ObservableObject {

    // MARK: - Dependencies

    private let sessionStore: SessionStore
    private let configStore: ConfigStore
    private let service = OpenAIService()

    // MARK: - Published state

    /// All sessions (delegated to the shared store).
    @Published var sessions: [ChatSession] = []

    /// The selected session id (single source of truth; sidebar reads this).
    @Published var activeSessionID: UUID?

    /// `true` while a stream request is in flight.
    @Published var isStreaming = false

    /// User-facing error banner text (nil hides the banner).
    @Published var errorMessage: String?

    /// Dismisses the error banner when set.
    @Published var errorDismissToken = 0

    // MARK: - Internal stream state

    /// The in-flight URLSessionDataTask (cancelled when the user stops).
    private var streamTask: URLSessionDataTask?

    /// Combine subscriptions for reactive sync.
    private var cancellables = Set<AnyCancellable>()

    /// Tracks the assistant message id currently being filled.
    var streamingAssistantID: UUID?

    // MARK: - Convenience

    /// The active session object, if any.
    var activeSession: ChatSession? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Messages for the active session.
    var activeMessages: [ChatMessage] {
        activeSession?.messages ?? []
    }

    // MARK: - Initializers

    init(sessionStore: SessionStore, configStore: ConfigStore) {
        self.sessionStore = sessionStore
        self.configStore = configStore

        self.sessions = sessionStore.sessions
        self.activeSessionID = sessionStore.activeSessionID

        // Mirror store changes into this VM (one-way: store → VM).
        // No sinks write back to the store, so no feedback loops occur.
        sessionStore.$sessions.sink { [weak self] newSessions in
            self?.sessions = newSessions
        }
        .store(in: &cancellables)

        sessionStore.$activeSessionID.sink { [weak self] newID in
            self?.activeSessionID = newID
        }
        .store(in: &cancellables)
    }

    // MARK: - Session management

    /// Creates a new empty chat and switches to it.
    func createNewChat() {
        cancelStreaming()
        sessionStore.newSession()
    }

    /// Deletes the given session.
    func deleteSession(_ session: ChatSession) {
        cancelStreaming()
        sessionStore.delete(session)
    }

    /// Selects an existing session.
    func selectSession(_ session: ChatSession) {
        guard session.id != activeSessionID else { return }
        cancelStreaming()
        sessionStore.activeSessionID = session.id
    }

    // MARK: - Sending messages

    /// Sends the user's text (optionally with image attachments) as a message
    /// and kicks off a streaming reply.
    func sendMessage(
        _ text: String,
        config: APIServerConfig?,
        model: String,
        attachments: [ImageAttachment] = []
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending when either text or at least one image is present.
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let sessionID = activeSessionID else { return }
        guard let config = config else {
            errorMessage = "No active API profile. Add one in Settings first."
            return
        }

        // Cancel any in-flight generation.
        cancelStreaming()
        clearError()

        // Persist the user message (with any image attachments).
        sessionStore.appendMessage(.user(trimmed, attachments: attachments), to: sessionID)

        // Append a placeholder assistant message that will fill as deltas land.
        let assistantMessage = ChatMessage.assistant()
        sessionStore.appendMessage(assistantMessage, to: sessionID)
        streamingAssistantID = assistantMessage.id

        // Snapshot the message history to send (includes the just-added user
        // message). Keep messages that have text OR image attachments — a
        // vision request may contain an empty-caption image.
        let history = sessionStore.activeSession?.messages
            .filter { !$0.content.isEmpty || !$0.attachments.isEmpty } ?? []

        let configForRequest = config
        let modelForRequest = model

        isStreaming = true

        streamTask = service.streamChat(
            config: configForRequest,
            model: modelForRequest,
            messages: history,
            onDelta: { [weak self] delta in
                guard let self = self else { return }
                // If the user switched sessions mid-stream, stop writing.
                guard self.activeSessionID == sessionID else {
                    self.cancelStreaming()
                    return
                }
                self.sessionStore.updateLastAssistantContent(
                    (self.sessionStore.activeSession?.messages.last?.content ?? "") + delta,
                    in: sessionID
                )
            },
            onComplete: { [weak self] in
                guard let self = self else { return }
                self.isStreaming = false
                self.streamTask = nil
                self.streamingAssistantID = nil
            },
            onError: { [weak self] error in
                guard let self = self else { return }
                self.isStreaming = false
                self.streamTask = nil
                self.streamingAssistantID = nil

                // If nothing was produced, remove the placeholder message.
                let partial = self.sessionStore.activeSession?
                    .messages.last(where: { $0.role == .assistant })
                if partial?.content.isEmpty == true {
                    self.sessionStore.removeLastAssistantMessage(in: sessionID)
                }

                self.errorMessage = error.localizedDescription
            }
        )
    }

    /// Stops the in-flight stream and saves partial content.
    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        streamingAssistantID = nil
    }

    // MARK: - Error handling

    func clearError() {
        errorMessage = nil
        errorDismissToken += 1
    }
}