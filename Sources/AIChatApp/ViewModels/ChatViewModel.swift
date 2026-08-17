import Foundation
import Combine
import AppKit

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

    /// `true` once the first non-empty SSE token has arrived while streaming.
    ///
    /// Experimental deferred-render mode: we still receive tokens over SSE
    /// (so time-to-first-token stays low) but do NOT render them one-by-one
    /// into the bubble. Instead we show "generating…" until the stream ends,
    /// then write the full text once and let Markdown render a single time.
    @Published var hasReceivedFirstToken = false

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

    /// Helper that returns the system prompt enriched with the user profile
    /// and (optionally) the current date/time.
    private func buildSystemPrompt(for config: APIServerConfig) -> String {
        var prompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = APIServerConfig.defaultSystemPrompt
        }

        // Optionally tell the model what time it is "now".
        if config.includeTimestamp {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE, MMM d, yyyy 'at' HH:mm"
            let timeString = formatter.string(from: Date())
            let timeZone = TimeZone.current.identifier

            prompt += """

            CURRENT TIME: \(timeString) (Time Zone: \(timeZone))
            """
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

    /// Copies a message's text to the system pasteboard.
    func copyMessage(_ message: ChatMessage) {
        let content = message.content.isEmpty ? "…" : message.content
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    /// Deletes a single message from the active session.
    func deleteMessage(_ message: ChatMessage) {
        guard let sessionID = activeSessionID else { return }
        // 若正在流式生成该消息，先停止。
        if message.id == streamingAssistantID {
            cancelStreaming()
        }
        sessionStore.deleteMessage(message, in: sessionID)
    }

    /// Re-generates an assistant reply by deleting it and letting the model
    /// answer the previous user message again.
    func retryMessage(_ message: ChatMessage) {
        guard message.role == .assistant, let sessionID = activeSessionID else { return }
        guard let config = configStore.activeConfig else {
            errorMessage = L("no.active.profile")
            return
        }

        // 若正在流式生成该消息，先停止。
        if message.id == streamingAssistantID {
            cancelStreaming()
        }

        // 删除这条 assistant 回复。
        sessionStore.deleteMessage(message, in: sessionID)
        clearError()

        // 构建历史：删除后的会话全部消息（应以上一条 user 消息结尾）+
        // system prompt。使用 `activeSession`（VM 单一数据源）。
        var history = activeSession?.messages
            .filter { !$0.content.isEmpty || !$0.attachments.isEmpty } ?? []

        let systemPrompt = buildSystemPrompt(for: config)
        history.insert(.system(systemPrompt), at: 0)

        startGeneration(
            sessionID: sessionID,
            config: config,
            model: config.selectedModel,
            history: history
        )
    }

    /// Selects an existing session.
    func selectSession(_ session: ChatSession) {
        guard session.id != activeSessionID else { return }
        cancelStreaming()
        sessionStore.activeSessionID = session.id
    }

    /// Selects a session by id (used by the sidebar List selection binding).
    func selectSession(id: UUID?) {
        guard let id, id != activeSessionID else { return }
        cancelStreaming()
        sessionStore.activeSessionID = id
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
            errorMessage = L("no.active.profile")
            return
        }

        // Cancel any in-flight generation before starting a new one.
        cancelStreaming()
        clearError()

        // Persist the user message (with any image attachments).
        sessionStore.appendMessage(.user(trimmed, attachments: attachments), to: sessionID)

        // Build the request history: prepend the editable system prompt,
        // then keep messages with text OR image attachments so pure-image
        // vision requests are preserved.
        //
        // IMPORTANT: use `self.activeSession` (driven by the UI's
        // activeSessionID) rather than `sessionStore.activeSession` — the
        // store's activeSessionID is only synchronized when selecting through
        // `selectSession`, while the sidebar List selection updates the VM
        // directly. Using the VM's active session guarantees the history sent
        // matches the chat currently displayed.
        var history = activeSession?.messages
            .filter { !$0.content.isEmpty || !$0.attachments.isEmpty } ?? []

        let systemPrompt = buildSystemPrompt(for: config)
        history.insert(.system(systemPrompt), at: 0)

        startGeneration(
            sessionID: sessionID,
            config: config,
            model: model,
            history: history
        )
    }

    // MARK: - Generation pipeline

    /// Starts a generation request (streaming or non-streaming) and wires it to
    /// the placeholder assistant message that appears in the UI.
    ///
    /// Shared by `sendMessage` and `retryMessage` so both paths produce the same
    /// streaming experience (placeholder bubble → SSE deltas → final persist).
    private func startGeneration(
        sessionID: UUID,
        config: APIServerConfig,
        model: String,
        history: [ChatMessage]
    ) {
        // While streaming, skip the per-flush UserDefaults encode + disk write
        // (the main cause of UI stutter); we'll force one save at the end.
        sessionStore.persistPaused = true

        // Append a placeholder assistant message that fills as deltas land.
        let assistantMessage = ChatMessage.assistant()
        sessionStore.appendMessage(assistantMessage, to: sessionID)
        streamingAssistantID = assistantMessage.id

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

                    if let changes = UserProfileStore.parse(from: reply) {
                        for cat in changes.removes {
                            self.userProfileStore.removeAll(category: cat)
                        }
                        for p in changes.upserts {
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

                // EXPERIMENTAL DEFERRED RENDER:
                // accumulate the whole reply over SSE but do NOT touch the
                // bubble's content while streaming (no per-delta redraws).
                // The placeholder stays empty showing "generating…"; once the
                // stream finishes we write the full text in one update and
                // Markdown renders exactly once.
                var accumulated = ""
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

                    // Signal the UI once we actually have content.
                    if !self.hasReceivedFirstToken
                        && !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.hasReceivedFirstToken = true
                    }
                }
                // One-shot render: write the full accumulated text once.
                self.sessionStore.updateLastAssistantContent(
                    Self.stripPersonalization(from: accumulated),
                    in: sessionID
                )
                self.hasReceivedFirstToken = false

                // After the full reply arrives, parse & store any new
                // personalization the model detected.
                if let changes = UserProfileStore.parse(from: accumulated) {
                    for cat in changes.removes {
                        self.userProfileStore.removeAll(category: cat)
                    }
                    for p in changes.upserts {
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
                self.hasReceivedFirstToken = false

            } catch {
                self.sessionStore.forcePersist()
                self.isStreaming = false
                self.streamTask = nil
                self.streamingAssistantID = nil
                self.hasReceivedFirstToken = false

                // Remove the placeholder assistant message if nothing arrived.
                let partial = self.activeSession?
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
        hasReceivedFirstToken = false
        streamingAssistantID = nil
    }

    // MARK: - Error handling

    func clearError() {
        errorMessage = nil
        errorDismissToken += 1
    }
}