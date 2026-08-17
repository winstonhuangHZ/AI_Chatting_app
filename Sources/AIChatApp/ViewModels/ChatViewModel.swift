import Foundation
import Combine

/// Drives the active chat session: sending messages, consuming the SSE
/// stream, and accumulating response tokens into the assistant message.
///
/// Modern Swift Concurrency implementation:
/// - `@MainActor` guarantees all state mutations happen on the main thread.
/// - Streaming uses `AsyncThrowingStream<String, Error>` from `OpenAIService`.
/// - Cancellation is handled via a structured `Task`.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Dependencies

    private let sessionStore: SessionStore
    private let configStore: ConfigStore
    private let service: OpenAIService

    /// Persisted user profile (learned preferences) sent alongside the prompt.
    let userProfileStore: UserProfileStore

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

    /// Cancels the in-flight streaming task (Stop button / session switch).
    private var streamTask: Task<Void, Never>?

    /// Combine subscriptions for reactive sync.
    private var cancellables = Set<AnyCancellable>()

    /// Tracks the assistant message id currently being filled.
    var streamingAssistantID: UUID?

    // MARK: - Convenience

    /// Helper that returns the system prompt enriched with the user profile.
    private func buildSystemPrompt(for config: APIServerConfig) -> String {
        var prompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = APIServerConfig.defaultSystemPrompt
        }

        if let profileJSON = userProfileStore.jsonPayload {
            prompt += """

            KNOWLEDGE ABOUT THE USER (use it to personalize your reply):
            \(profileJSON)
            """
        }
        return prompt
    }

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

    init(
        sessionStore: SessionStore,
        configStore: ConfigStore,
        service: OpenAIService,
        userProfileStore: UserProfileStore = UserProfileStore()
    ) {
        self.sessionStore = sessionStore
        self.configStore = configStore
        self.service = service
        self.userProfileStore = userProfileStore

        self.sessions = sessionStore.sessions
        self.activeSessionID = sessionStore.activeSessionID

        // Mirror store changes into this VM (one-way: store → VM).
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
    /// and kicks off a streaming reply using Swift Concurrency.
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

        // Cancel any in-flight generation before starting a new one.
        cancelStreaming()
        clearError()

        // Persist the user message (with any image attachments).
        sessionStore.appendMessage(.user(trimmed, attachments: attachments), to: sessionID)

        // While streaming, skip the per-flush UserDefaults encode + disk write
        // (the main cause of UI stutter); we'll force one save at the end.
        sessionStore.persistPaused = true

        // Append a placeholder assistant message that fills as deltas land.
        let assistantMessage = ChatMessage.assistant()
        sessionStore.appendMessage(assistantMessage, to: sessionID)
        streamingAssistantID = assistantMessage.id

        // Build the request history: prepend the editable system prompt,
        // then keep messages with text OR image attachments so pure-image
        // vision requests are preserved.
        var history = sessionStore.activeSession?.messages
            .filter { !$0.content.isEmpty || !$0.attachments.isEmpty } ?? []

        let systemPrompt = buildSystemPrompt(for: config)
        history.insert(.system(systemPrompt), at: 0)

        isStreaming = true

        let service = service
        let configForRequest = config
        let modelForRequest = model

        streamTask = Task { [weak self] in
            guard let self else { return }

            do {
                // In non-streaming mode we wait for the whole response at once.
                if !configForRequest.streamEnabled {
                    let reply = try await service.chatOnce(
                        config: configForRequest,
                        model: modelForRequest,
                        messages: history
                    )

                    // Persist the full reply (with personalization stripped).
                    let cleaned = Self.stripPersonalization(from: reply)
                    self.sessionStore.updateLastAssistantContent(cleaned, in: sessionID)

                    if let prefs = UserProfileStore.parse(from: reply) {
                        for p in prefs {
                            self.userProfileStore.upsert(category: p.category, value: p.value)
                        }
                    }

                    self.sessionStore.forcePersist()
                    self.isStreaming = false
                    self.streamTask = nil
                    self.streamingAssistantID = nil
                    return
                }

                // Streaming mode: `streamChat` is an actor method — requires
                // `await` (Swift 6 strict concurrency). It returns an
                // AsyncThrowingStream.
                let stream = try await service.streamChat(
                    config: configForRequest,
                    model: modelForRequest,
                    messages: history
                )

                var accumulated = ""
                // Throttle UI updates so tiny SSE chunks don't trigger a full
                // SwiftUI redraw every time. We flush at most every 50 ms.
                var lastFlush = ContinuousClock.now
                for try await delta in stream {
                    // If the user switched sessions mid-stream, stop writing.
                    guard self.activeSessionID == sessionID else {
                        self.cancelStreaming()
                        return
                    }
                    // `bytes.lines` splits on \n and drops the newline; we
                    // must re-add it so Markdown blocks (tables, lists,
                    // code fences) stay intact across SSE chunks.
                    accumulated += delta + "\n"

                    // 50 ms throttle: only flush to the UI when enough time
                    // has passed (and always flush on the final iteration).
                    if lastFlush.duration(to: .now) > .milliseconds(50) {
                        lastFlush = .now
                        self.sessionStore.updateLastAssistantContent(
                            Self.stripPersonalization(from: accumulated),
                            in: sessionID
                        )
                    }
                }
                // Always flush the final accumulated text after the stream ends.
                self.sessionStore.updateLastAssistantContent(
                    Self.stripPersonalization(from: accumulated),
                    in: sessionID
                )

                // After the full reply arrives, parse & store any new
                // personalization the model detected.
                if let prefs = UserProfileStore.parse(from: accumulated) {
                    for p in prefs {
                        self.userProfileStore.upsert(category: p.category, value: p.value)
                    }
                }

                // Stream finished normally.
                self.sessionStore.forcePersist()
                self.isStreaming = false
                self.streamTask = nil
                self.streamingAssistantID = nil

            } catch is CancellationError {
                // User cancelled — keep any partial content.
                self.sessionStore.forcePersist()
                self.isStreaming = false
                self.streamTask = nil
                self.streamingAssistantID = nil

            } catch {
                self.sessionStore.forcePersist()
                self.isStreaming = false
                self.streamTask = nil
                self.streamingAssistantID = nil

                // Remove the placeholder assistant message if nothing arrived.
                let partial = self.sessionStore.activeSession?
                    .messages.last(where: { $0.role == .assistant })
                if partial?.content.isEmpty == true {
                    self.sessionStore.removeLastAssistantMessage(in: sessionID)
                }

                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Removes the invisible `<!-- PERSONALIZATION: ... -->` wrapper from a
    /// reply so it never shows in the rendered bubble or the stored message.
    private static func stripPersonalization(from text: String) -> String {
        guard let start = text.range(of: "<!-- PERSONALIZATION:") else { return text }
        guard let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) else {
            return String(text[..<start.lowerBound])
        }
        var result = text
        result.removeSubrange(start.lowerBound..<end.upperBound)
        return result
            .trimmingCharacters(in: .whitespacesAndNewlines)
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