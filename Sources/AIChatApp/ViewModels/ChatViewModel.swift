import Foundation
import Combine
import AppKit

/// A transient toast describing a memory (user-profile) change the AI made.
struct MemoryNotice: Identifiable, Equatable {
    /// Stable identity so SwiftUI can animate toasts in/out.
    let id: UUID

    /// Number of preferences added or updated.
    let addedCount: Int

    /// Number of preferences removed.
    let removedCount: Int

    /// When the change happened.
    let timestamp: Date

    init(id: UUID = UUID(), addedCount: Int, removedCount: Int, timestamp: Date) {
        self.id = id
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.timestamp = timestamp
    }
}

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
    /// Non-streaming render mode still uses SSE transport (low time-to-first-
    /// token) but delays rendering until the stream ends; this flag drives the
    /// "Waiting for response…" → "Generating…" two-stage indicator.
    @Published var hasReceivedFirstToken = false

    /// User-facing toast when the model added/updated/removed memories.
    @Published var memoryNotice: MemoryNotice?

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

    // MARK: - Memory application

    /// Applies parsed profile changes and surfaces a UI toast so the user
    /// knows their memory was silently modified by the AI.
    private func applyProfileChanges(_ changes: ProfileChanges) {
        var added = 0
        var removed = 0

        for p in changes.upserts {
            // True "added" vs "updated" is hard to know for sure from the
            // model's perspective; count every upsert as an add/update.
            userProfileStore.upsert(category: p.category, value: p.value)
            added += 1
        }
        for cat in changes.removes {
            let before = userProfileStore.preferences.filter {
                $0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == cat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.count
            userProfileStore.removeAll(category: cat)
            removed += before
        }

        guard added > 0 || removed > 0 else { return }
        memoryNotice = MemoryNotice(
            addedCount: added,
            removedCount: removed,
            timestamp: Date()
        )
    }

    // MARK: - Convenience

    /// Builds the **static** system prompt.
    ///
    /// Cache-optimization: this string is byte-for-byte stable across requests
    /// (no timestamp, no profile JSON), so the relay's prompt-cache prefix is
    /// maximized. Dynamic context (current time + user profile) is appended as
    /// a separate trailing system message by `buildContextMessage`.
    private func buildSystemPrompt(for config: APIServerConfig) -> String {
        var prompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = APIServerConfig.defaultSystemPrompt
        }

        // 渐进增强：老配置里保存的 systemPrompt 可能缺少「删除/修改偏好」指令，
        // 自动补齐，让模型可以按新协议更新 personalization。
        let deleteMarker = "\"op\": \"remove\""
        let updateMarker = "To UPDATE an existing preference"
        if !prompt.contains(deleteMarker) || !prompt.contains(updateMarker) {
            prompt += """

            PERSONALIZATION OPS: You may modify the user profile preferences \
            stored by the app. To DELETE an outdated preference, send:
            <!-- PERSONALIZATION: {"preferences": [{"op": "remove", "category": "location"}]} -->
            To UPDATE an existing preference, send the same category with a new value:
            <!-- PERSONALIZATION: {"preferences": [{"category": "language", "value": "English"}]} -->
            """
        }
        // 渐进增强：老配置可能没有「标记可放开头/结尾」的说明，自动补齐，
        // 避免模型只在回复末尾才想起写个人化标记而漏掉。
        let startMarker = "AT THE VERY START"
        if !prompt.contains(startMarker) {
            prompt += """

            PERSONALIZATION PLACEMENT: The invisible PERSONALIZATION note may be \
            placed AT THE VERY START of your reply (before the visible answer) \
            OR at the very end — both are detected and stripped automatically. \
            Emit it as soon as you know the preference; do not wait until the end.
            """
        }

        // 渐进增强：告知模型「最新 user 消息开头的时间戳」是系统注入的当前时间。
        let tsMarker = "TIMESTAMP NOTE"
        if !prompt.contains(tsMarker) {
            prompt += """

            TIMESTAMP NOTE: The newest USER message may carry a leading timestamp \
            in square brackets, e.g. "[2026-08-19 01:02:03] ...". It is injected \
            by the app itself — treat it as the system-provided current time \
            whenever the user asks about time/date. Never fabricate or guess a \
            time; always use the provided timestamp as ground truth for "now".
            """
        }
        return prompt
    }

    /// Builds the **dynamic** trailing context: learned user profile only.
    ///
    /// The current time no longer lives here — it is injected into the newest
    /// user message (see `timestamppedHistory`) so the request's long static
    /// prefix stays byte-identical AND the model still sees an exact timestamp
    /// close to the question. Dynamic profile JSON remains the LAST message so
    /// prefix caching is unaffected by profile edits.
    ///
    /// Returns `nil` when there is no profile data to send.
    private func buildContextMessage(for config: APIServerConfig) -> ChatMessage? {
        guard let profileJSON = userProfileStore.jsonPayload else { return nil }
        return .system("""
        KNOWLEDGE ABOUT THE USER (use it to personalize your reply):
        \(profileJSON)
        """)
    }

    /// Prepends a precise (second-granularity) timestamp to the newest user
    /// message — only in the copy sent to the API, never persisted to storage.
    ///
    /// Cache-optimization: the timestamp sits at the very end of the growing
    /// history (the latest user message), so every older token (static system
    /// prompt + previous turns) stays byte-identical across minutes → DeepSeek
    /// & friends keep hitting the prefix cache while still giving the model an
    /// exact "now" near the question.
    private func timestamppedHistory(
        _ history: [ChatMessage],
        config: APIServerConfig
    ) -> [ChatMessage] {
        guard config.includeTimestamp,
              var last = history.last,
              last.role == .user,
              !last.content.isEmpty else { return history }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: Date())

        last.content = "[\(stamp)] \(last.content)"
        var result = history
        result[result.count - 1] = last
        return result
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
        //
        // 缓存优化：静态 system prompt 在最前，动态上下文（时间+偏好）
        // 作为最后一条 system 消息，保持前缀字节不变以提高中继缓存命中。
        var history = activeSession?.messages
            .filter { !$0.content.isEmpty || !$0.attachments.isEmpty } ?? []

        let systemPrompt = buildSystemPrompt(for: config)
        history.insert(.system(systemPrompt), at: 0)

        // 精确时间戳注入最新 user（不污染存储），前缀保持字节稳定。
        history = timestamppedHistory(history, config: config)

        // 动态偏好 JSON 保留在最后（动态 context 需在末尾以保前缀命中）。
        if let context = buildContextMessage(for: config) {
            history.append(context)
        }

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

        // 精确时间戳注入最新 user（不污染存储），前缀保持字节稳定。
        history = timestamppedHistory(history, config: config)

        // 动态偏好 JSON 保留在最后（动态 context 需在末尾以保前缀命中）。
        if let context = buildContextMessage(for: config) {
            history.append(context)
        }

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
                // NON-STREAMING RENDER MODE (transport is still SSE/streamed):
                // accumulate the whole reply over the SSE stream but do NOT
                // update the bubble token-by-token. The placeholder stays empty
                // showing "waiting/generating…"; once the stream ends we write
                // the full text in one update and Markdown renders exactly once.
                if !configForRequest.streamEnabled {
                    let stream = try await service.streamChat(
                        config: configForRequest,
                        model: modelForRequest,
                        messages: history
                    )

                    var accumulated = ""
                    for try await delta in stream {
                        guard self.activeSessionID == sessionID else {
                            self.cancelStreaming()
                            return
                        }
                        // `delta.content` is already JSON-decoded; real newlines
                        // are preserved inside the string, so do NOT append a
                        // synthetic "\n" per frame.
                        accumulated += delta

                        if !self.hasReceivedFirstToken
                            && !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.hasReceivedFirstToken = true
                        }
                    }
                    // One-shot render.
                    self.sessionStore.updateLastAssistantContent(
                        Self.stripPersonalization(from: accumulated),
                        in: sessionID
                    )
                    self.hasReceivedFirstToken = false

                    if let changes = UserProfileStore.parse(from: accumulated) {
                        self.applyProfileChanges(changes)
                    }

                    self.sessionStore.forcePersist()
                    self.isStreaming = false
                    self.streamTask = nil
                    self.streamingAssistantID = nil
                    return
                }

                // STREAMING RENDER MODE: `streamChat` yields deltas and we
                // update the bubble token-by-token (throttled to ~100ms).
                let stream = try await service.streamChat(
                    config: configForRequest,
                    model: modelForRequest,
                    messages: history
                )

                var accumulated = ""
                // Throttle UI updates so tiny SSE chunks don't trigger a full
                // SwiftUI redraw every time. We flush at most every 100 ms.
                var lastFlush = ContinuousClock.now
                for try await delta in stream {
                    // If the user switched sessions mid-stream, stop writing.
                    guard self.activeSessionID == sessionID else {
                        self.cancelStreaming()
                        return
                    }
                    // IMPORTANT: do NOT append a synthetic "\n" after each
                    // delta. The `delta.content` from OpenAI-compatible SSE is
                    // already JSON-decoded, so any real newlines inside the
                    // model's reply are already preserved as "\n" characters
                    // inside the string. If we add "\n" per delta, relays that
                    // stream one character per frame produce a broken message
                    // where every character is on its own line (and that
                    // corrupted text gets persisted into history).
                    accumulated += delta

                    // 100 ms throttle: only flush to the UI when enough time
                    // has passed (and always flush on the final iteration).
                    if lastFlush.duration(to: .now) > .milliseconds(100) {
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
                if let changes = UserProfileStore.parse(from: accumulated) {
                    self.applyProfileChanges(changes)
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

    /// Removes **all** invisible `<!-- PERSONALIZATION: ... -->` wrappers from
    /// a reply so they never show in the rendered bubble or stored message.
    ///
    /// The model may emit the marker at the START, MIDDLE, or END of a reply;
    /// every occurrence is stripped (the parser accepts any location too).
    private static func stripPersonalization(from text: String) -> String {
        var result = text
        while let start = result.range(of: "<!-- PERSONALIZATION:") {
            guard let end = result.range(of: "-->", range: start.upperBound..<result.endIndex) else {
                // Unterminated marker — drop everything from the marker on.
                result = String(result[..<start.lowerBound])
                break
            }
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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