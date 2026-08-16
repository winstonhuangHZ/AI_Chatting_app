import Foundation
import Combine

/// Drives the active chat session: sending messages, consuming the SSE
/// stream, and accumulating response tokens into the assistant message.
///
/// Uses the callback-based `OpenAIService` (no async/await) so it compiles
/// with older SDKs. All network callbacks arrive on the main queue.
final class ChatViewModel: ObservableObject {

    // MARK: - Dependencies

    private let sessionStore: SessionStore
    private let configStore: ConfigStore
    private let service = OpenAIService()

    // MARK: - Published state

    /// All sessions (delegated to the shared store).
    @Published var sessions: [ChatSession] = []

    /// The selected session id (delegated to the shared store).
    @Published var activeSessionID: UUID?

    /// `true` while a stream request is in flight.
    @Published var isStreaming = false

    /// Selection binding fed to the sidebar `List`.
    @Published var selectedSessionID: UUID?

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
        self.selectedSessionID = sessionStore.activeSessionID

        sessionStore.$sessions.assign(to: &$sessions)
        sessionStore.$activeSessionID.assign(to: &$activeSessionID)

        // Keep the sidebar selection in sync with the active session.
        $activeSessionID
            .dropFirst()
            .sink { [weak self] newID in
                self?.selectedSessionID = newID
            }
            .store(in: &cancellables)

        // When the user clicks a sidebar row, switch the active session.
        $selectedSessionID
            .dropFirst()
            .sink { [weak self] newID in
                guard let newID else { return }
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

    /// Selects a session by id (used by the list selection binding).
    func selectSessionID(_ id: UUID?) {
        guard let id, let session = sessions.first(where: { $0.id == id }) else { return }
        selectSession(session)
    }

    // MARK: - Sending messages

    /// Sends the user's text as a message and kicks off a streaming reply.
    func sendMessage(_ text: String, config: APIServerConfig?, model: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let sessionID = activeSessionID else { return }
        guard let config else {
            errorMessage = "No active API profile. Add one in Settings first."
            return
        }

        // Cancel any in-flight generation.
        cancelStreaming()
        clearError()

        // Persist the user message.
        sessionStore.appendMessage(.user(trimmed), to: sessionID)

        // Append a placeholder assistant message that will fill as deltas land.
        let assistantMessage = ChatMessage.assistant()
        sessionStore.appendMessage(assistantMessage, to: sessionID)
        streamingAssistantID = assistantMessage.id

        // Snapshot the message history to send (includes the just-added user message).
        let history = sessionStore.activeSession?.messages
            .filter { !$0.content.isEmpty } ?? []

        let service = service
        let configForRequest = config
        let modelForRequest = model

        isStreaming = true

        streamTask = service.streamChat(
            config: configForRequest,
            model: modelForRequest,
            messages: history,
            onDelta: { [weak self] delta in
                guard let self else { return }
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
                guard let self else { return }
                self.isStreaming = false
                self.streamTask = nil
                self.streamingAssistantID = nil
            },
            onError: { [weak self] error in
                guard let self else { return }
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