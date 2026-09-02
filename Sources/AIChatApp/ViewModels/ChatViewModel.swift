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

    /// Transient banner explaining a cache reset caused by a profile change or
    /// by the user editing the conversation history (delete/regenerate).
    struct CacheResetNotice: Identifiable, Equatable {
        enum Reason {
            /// The shared profile message changed → whole-history prefix reset.
            case profileChanged
            /// A message was deleted/regenerated → prefix diverges from that point.
            case historyEdited
        }

        let id: UUID
        let reason: Reason

        init(id: UUID = UUID(), reason: Reason) {
            self.id = id
            self.reason = reason
        }
    }

/// A chat message matching the sidebar full-text search.
struct MessageSearchResult: Identifiable, Equatable {
    /// Message id (stable identity for list rows + scroll target).
    let id: UUID

    /// Session the message belongs to.
    let sessionID: UUID

    /// Session title shown above the snippet.
    let sessionTitle: String

    /// The matched message itself.
    let message: ChatMessage

    /// Short excerpt around the first match.
    let snippet: String
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

    /// User-facing toast when the shared profile changed since the last
    /// request — the relay's cache prefix is therefore reset for this history.
    @Published var cacheResetNotice: CacheResetNotice?

    /// Fingerprint of the profile payload the previous request was built with.
    private var lastProfilePayloadHash: String?

    /// User-facing error banner text (nil hides the banner).
    @Published var errorMessage: String?

    /// Dismisses the error banner when set.
    @Published var errorDismissToken = 0

    /// Token usage (incl. cache hit/miss) reported by the relay for the most
    /// recent completed request. `nil` until a relay provides the data.
    @Published var lastCacheUsage: StreamUsage?

    // MARK: - Full-text search

    /// Sidebar search query (empty = normal session list).
    @Published var searchQuery = ""

    /// Message id to scroll to + highlight after jumping from a search result.
    @Published var highlightMessageID: UUID?

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

    /// Detects whether the shared profile changed since the previous request.
    ///
    /// The profile message sits at index 1 of the byte-identical cache prefix,
    /// so a profile change resets the relay's cache for the WHOLE conversation
    /// history (hit rate collapses to just the system prompt). We surface that
    /// as a banner instead of letting the drop look like a random bug. The
    /// change was applied when the previous reply finished; it only becomes
    /// visible when the next request is being built.
    private func trackProfileChange() {
        let hash = userProfileStore.payloadHash
        if let last = lastProfilePayloadHash, last != hash {
            cacheResetNotice = CacheResetNotice(reason: .profileChanged)
        }
        lastProfilePayloadHash = hash
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
        //
        // 缓存血泪（实测）：profile 消息固定在 messages 第 1 位，模型每
        // upsert/remove 一条偏好，profile JSON 就变化一次，其后的整段会话
        // 历史全部缓存失配（命中率从 99% 崩到 ~28%）。所以这里的指令刻意
        // 收紧：只允许写入持久稳定的事实，禁止当前话题/一次性事件/易变状态。
        let deleteMarker = "\"op\": \"remove\""
        let updateMarker = "To UPDATE an existing preference"
        let durableMarker = "DURABLE FACTS ONLY"
        if !prompt.contains(deleteMarker) || !prompt.contains(updateMarker) || !prompt.contains(durableMarker) {
            prompt += """

            PERSONALIZATION OPS: You may modify the user profile preferences \
            stored by the app. To DELETE an outdated preference, send:
            <!-- PERSONALIZATION: {"preferences": [{"op": "remove", "category": "location"}]} -->
            To UPDATE an existing preference, send the same category with a new value:
            <!-- PERSONALIZATION: {"preferences": [{"category": "language", "value": "English"}]} -->
            DURABLE FACTS ONLY — CRITICAL: persist ONLY stable, long-term facts \
            about the user (name, language, location, occupation, skills, fixed \
            preferences). NEVER write: topics of the current conversation, one-off \
            events, dates/scores/deadlines/statuses that change over time (exam \
            dates, results, schedules), or anything already visible in the \
            conversation. When a fact changes, UPDATE the existing entry (same \
            category, new value) — never append a duplicate.
            """
        }
        // 渐进增强：老配置可能没有「标记可放开头/结尾」的说明，自动补齐，
        // 避免模型只在回复末尾才想起写个人化标记而漏掉。
        let startMarker = "AT THE VERY START"
        let restraintMarker = "ONLY when you learn"
        if !prompt.contains(startMarker) || !prompt.contains(restraintMarker) {
            prompt += """

            PERSONALIZATION PLACEMENT: The invisible PERSONALIZATION note may be \
            placed AT THE VERY START of your reply (before the visible answer) \
            OR at the very end — both are detected and stripped automatically. \
            Emit it ONLY when you learn a genuinely durable fact (see DURABLE \
            FACTS ONLY); never pollute the profile with conversation topics.
            """
        }

        // 渐进增强：告知模型用 get_time 工具获取当前时间。
        let tsMarker = "TIMESTAMP NOTE"
        if !prompt.contains(tsMarker) {
            prompt += """

            TIMESTAMP NOTE: You have a get_time tool. Whenever the user asks about \
            the current time, date, or "now", call get_time and use its returned \
            value as ground truth. Never guess or fabricate a time.
            """
        }
        return prompt
    }

    /// Builds the **dynamic** trailing context: learned user profile only.
    ///
    /// The current time is no longer injected as a message — the model gets it
    /// via the `get_time` tool when needed (cache-safe: tool results never
    /// persist). Dynamic profile JSON remains the LAST message so prefix
    /// caching is unaffected by profile edits.
    ///
    /// Returns `nil` when there is no profile data to send.
    private func buildContextMessage(for config: APIServerConfig) -> ChatMessage? {
        guard let profileJSON = userProfileStore.jsonPayload else { return nil }
        return .system("""
        KNOWLEDGE ABOUT THE USER (use it to personalize your reply):
        \(profileJSON)
        """)
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

        // 第一轮对话的 AI 通过 set_session_metadata 工具挑选会话 emoji/标题。
        // 全局 sink：工具在后台线程执行，跳回主线程后应用到当前活动会话。
        ChatTools.sessionMetadataSink = { [weak self] emoji, title in
            guard let self, let sessionID = self.activeSessionID else { return }
            self.sessionStore.updateSessionMetadata(emoji: emoji, title: title, in: sessionID)
        }

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
        // 删除消息会改变该会话历史的字节前缀 → 下次请求缓存从删除点起重置。
        cacheResetNotice = CacheResetNotice(reason: .historyEdited)
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

        // 重试=删除+重发：历史字节前缀从删除点重置 → 显式提示。
        cacheResetNotice = CacheResetNotice(reason: .historyEdited)

        // 若共享 profile 自上次请求后变化，缓存前缀将重置 —— 先记录以便提示。
        trackProfileChange()

        // 构建历史：删除后的会话全部消息（应以上一条 user 消息结尾）+
        // system prompt。使用 `activeSession`（VM 单一数据源）。
        //
        // 缓存优化：静态 system prompt 在最前，动态上下文（时间+偏好）
        // 作为最后一条 system 消息，保持前缀字节不变以提高中继缓存命中。
        var history = activeSession?.messages
            .filter { !$0.content.isEmpty || !$0.attachments.isEmpty } ?? []

        let systemPrompt = buildSystemPrompt(for: config)
        history.insert(.system(systemPrompt), at: 0)

        // 动态偏好 JSON 紧跟 system prompt 放在最前：上一轮请求的完整
        // messages 单元会成为下一轮的前缀，DeepSeek 的“完整单元匹配”
        // 缓存才能每轮命中历史（放末尾会让每轮单元都含不同结尾而无法匹配）。
        if let context = buildContextMessage(for: config) {
            history.insert(context, at: 1)
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

    /// Sends the user's text (optionally with image / PDF attachments) as a
    /// message and kicks off a streaming reply using Swift Concurrency.
    func sendMessage(
        _ text: String,
        config: APIServerConfig?,
        model: String,
        attachments: [ImageAttachment] = [],
        documents: [DocumentAttachment] = []
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending when either text or at least one attachment is present.
        guard !trimmed.isEmpty || !attachments.isEmpty || !documents.isEmpty else { return }
        guard let sessionID = activeSessionID else { return }
        guard let config = config else {
            errorMessage = L("no.active.profile")
            return
        }

        // Cancel any in-flight generation before starting a new one.
        cancelStreaming()
        clearError()

        // Persist the user message (with any attachments).
        sessionStore.appendMessage(
            .user(trimmed, attachments: attachments, documents: documents),
            to: sessionID
        )

        // 若共享 profile 自上次请求后变化，缓存前缀将重置 —— 先记录以便提示。
        trackProfileChange()

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
            .filter { !$0.content.isEmpty || !$0.attachments.isEmpty || !$0.documentAttachments.isEmpty } ?? []

        let systemPrompt = buildSystemPrompt(for: config)
        history.insert(.system(systemPrompt), at: 0)

        // 动态偏好 JSON 紧跟 system prompt 放在最前：上一轮请求的完整
        // messages 单元会成为下一轮的前缀，DeepSeek 的“完整单元匹配”
        // 缓存才能每轮命中历史（放末尾会让每轮单元都含不同结尾而无法匹配）。
        if let context = buildContextMessage(for: config) {
            history.insert(context, at: 1)
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
        // Record the model so the message-info popover can show it.
        var assistantMessage = ChatMessage.assistant()
        assistantMessage.model = model
        sessionStore.appendMessage(assistantMessage, to: sessionID)
        streamingAssistantID = assistantMessage.id

        isStreaming = true

        let service = service
        let configForRequest = config
        let modelForRequest = model

        streamTask = Task { [weak self] in
            guard let self else { return }

            do {
                // AGENT MODE / TIME: built-in tool calling. Agent mode sends the
                // full tool set; non-agent chats send only `get_time` when the
                // "timestamp" toggle is on (cache-safe: tool results are never
                // persisted, so the request prefix stays byte-identical).
                if configForRequest.toolsEnabled || configForRequest.includeTimestamp {
                    // 第一轮对话：历史里还没有任何 assistant 回复。此时才把
                    // set_session_metadata 广告给模型，让 AI 挑选会话 emoji/标题。
                    let isFirstRound = history.filter { $0.role == .assistant }.isEmpty
                    let toolSet: [BuiltinTool]? = configForRequest.toolsEnabled
                        ? ChatTools.set(
                            latexEnabled: configForRequest.latexEnabled,
                            includeSessionMetadata: isFirstRound
                        )
                        : (isFirstRound
                            ? [ChatTools.getTime, ChatTools.setSessionMetadata]
                            : [ChatTools.getTime])
                    let stream = try await service.streamChatWithTools(
                        config: configForRequest,
                        model: modelForRequest,
                        messages: history,
                        tools: toolSet,
                        usageHandler: { [weak self] usage in
                            Task { @MainActor in self?.lastCacheUsage = usage }
                        }
                    )
                    try await self.consumeToolEvents(
                        stream,
                        sessionID: sessionID,
                        renderAsYouGo: configForRequest.streamEnabled
                    )
                    return
                }

                // NON-STREAMING RENDER MODE (transport is still SSE/streamed):
                // accumulate the whole reply over the SSE stream but do NOT
                // update the bubble token-by-token. The placeholder stays empty
                // showing "waiting/generating…"; once the stream ends we write
                // the full text in one update and Markdown renders exactly once.
                if !configForRequest.streamEnabled {
                    let stream = try await service.streamChat(
                        config: configForRequest,
                        model: modelForRequest,
                        messages: history,
                        usageHandler: { [weak self] usage in
                            Task { @MainActor in self?.lastCacheUsage = usage }
                        },
                        reasoningHandler: { [weak self] reasoning in
                            Task { @MainActor in
                                self?.sessionStore.updateLastAssistantReasoning(reasoning, in: sessionID)
                            }
                        }
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
                        Self.finalReply(accumulated),
                        in: sessionID
                    )
                    self.hasReceivedFirstToken = false

                    if let changes = UserProfileStore.parse(from: accumulated) {
                        self.applyProfileChanges(changes)
                    }

                    self.persistLastUsage(to: sessionID)
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
                    messages: history,
                    usageHandler: { [weak self] usage in
                        Task { @MainActor in self?.lastCacheUsage = usage }
                    },
                    reasoningHandler: { [weak self] reasoning in
                        Task { @MainActor in
                            self?.sessionStore.updateLastAssistantReasoning(reasoning, in: sessionID)
                        }
                    }
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
                            Self.stripReplyMarkup(accumulated),
                            in: sessionID
                        )
                    }
                }
                // Always flush the final accumulated text after the stream ends.
                self.sessionStore.updateLastAssistantContent(
                    Self.finalReply(accumulated),
                    in: sessionID
                )

                // After the full reply arrives, parse & store any new
                // personalization the model detected.
                if let changes = UserProfileStore.parse(from: accumulated) {
                    self.applyProfileChanges(changes)
                }

                self.persistLastUsage(to: sessionID)

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
    /// Consumes a tool-mode `ChatStreamEvent` stream (Agent mode).
    ///
    /// Tool activity is written straight into the placeholder assistant
    /// bubble ("🔧 running web_search…"), then the final answer text streams
    /// normally. In non-streaming mode (`renderAsYouGo == false`) text is
    /// rendered once at the end, exactly like the plain chat path.
    private func consumeToolEvents(
        _ stream: AsyncThrowingStream<ChatStreamEvent, Error>,
        sessionID: UUID,
        renderAsYouGo: Bool
    ) async throws {
        var accumulated = ""
        var lastFlush = ContinuousClock.now
        var collectedSources: [ChatSource] = []
        var toolFlow: [MessageToolCallRecord] = []

        for try await event in stream {
            // If the user switched sessions mid-stream, stop writing.
            guard activeSessionID == sessionID else {
                cancelStreaming()
                return
            }
            switch event {
            case .text(let delta):
                accumulated += delta
                if !hasReceivedFirstToken
                    && !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasReceivedFirstToken = true
                }
                // Throttle UI updates to ~100 ms (streaming render only).
                if renderAsYouGo, lastFlush.duration(to: .now) > .milliseconds(100) {
                    lastFlush = .now
                    sessionStore.updateLastAssistantContent(
                        Self.stripReplyMarkup(accumulated),
                        in: sessionID
                    )
                }
            case .toolActivity(let toolName):
                sessionStore.updateLastAssistantContent(
                    L("agent.tool.running", toolName),
                    in: sessionID
                )
            case .toolFinished(let toolName):
                if accumulated.isEmpty {
                    sessionStore.updateLastAssistantContent(
                        L("agent.tool.done", toolName),
                        in: sessionID
                    )
                }
            case .sources(let list):
                collectedSources.append(contentsOf: list)
            case .usage(let usage):
                lastCacheUsage = usage
            case .toolRecord(let record):
                toolFlow.append(record)
            case .reasoning(let r):
                // DeepSeek reasoning text for the final answer — persist it so
                // the next request can pass it back.
                sessionStore.updateLastAssistantReasoning(r, in: sessionID)
            }
        }

        // Always flush the final accumulated text after the stream ends.
        sessionStore.updateLastAssistantContent(
            Self.finalReply(accumulated),
            in: sessionID
        )

        // Attach web-source references collected during the tool loop.
        if !collectedSources.isEmpty {
            sessionStore.updateLastAssistantSources(collectedSources, in: sessionID)
        }

        // Persist generation metadata for the message-info popover.
        if !toolFlow.isEmpty {
            sessionStore.updateLastAssistantToolFlow(toolFlow, in: sessionID)
        }
        persistLastUsage(to: sessionID)

        // After the full reply arrives, parse & store any new personalization.
        if let changes = UserProfileStore.parse(from: accumulated) {
            applyProfileChanges(changes)
        }

        sessionStore.forcePersist()
        isStreaming = false
        streamTask = nil
        streamingAssistantID = nil
        hasReceivedFirstToken = false
    }


    /// Copies the last relay-reported usage onto the just-finished assistant
    /// message so the message-info popover can show real token numbers.
    private func persistLastUsage(to sessionID: UUID) {
        guard let usage = lastCacheUsage else { return }
        sessionStore.updateLastAssistantUsage(MessageUsage(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            cacheHitTokens: usage.cacheHitTokens,
            cacheMissTokens: usage.cacheMissTokens
        ), in: sessionID)
    }

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

    /// Removes hallucinated XML tool-call markup (`<tool_calls>` / `<invoke>` /
    /// `<parameter>`) from a reply. Some models (DeepSeek) emit Claude-style
    /// XML tool calls as plain text when they want to search more but the tool
    /// budget is exhausted — that markup must never reach the rendered bubble.
    ///
    /// Fence-aware: literal XML examples inside markdown code blocks are kept.
    private static func stripToolCallMarkup(from text: String) -> String {
        // Backreference \1: the closing tag must match the opening tag type, so
        // an inner </invoke> inside <tool_calls>…</tool_calls> is consumed as
        // content rather than ending the match early.
        let blockPattern = #"(?is)<(tool_calls|invoke)\b[^>]*>.*?</\1\s*>"#
        // Split by ``` fences; even-indexed segments are OUTSIDE fences.
        let components = text.components(separatedBy: "```")
        var result = ""
        for (index, part) in components.enumerated() {
            if index % 2 == 0 {
                result += part.replacingOccurrences(
                    of: blockPattern,
                    with: "",
                    options: .regularExpression
                )
            } else {
                result += part
            }
            if index < components.count - 1 {
                result += "```"
            }
        }
        // Stray `<parameter …>…</parameter>` elements left after a truncated
        // invocation block are removed too (but only outside code fences).
        let components2 = result.components(separatedBy: "```")
        var result2 = ""
        for (index, part) in components2.enumerated() {
            if index % 2 == 0 {
                result2 += part.replacingOccurrences(
                    of: #"(?is)<parameter\b[^>]*>.*?</parameter\s*>"#,
                    with: "",
                    options: .regularExpression
                )
            } else {
                result2 += part
            }
            if index < components2.count - 1 {
                result2 += "```"
            }
        }
        return result2.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns `true` when the reply contains tool-call markup that we would
    /// strip — used to decide the empty-answer fallback.
    private static func containsToolCallMarkup(_ text: String) -> Bool {
        text.range(of: #"(?i)<tool_calls\b"#, options: .regularExpression) != nil
            || text.range(of: #"(?i)<invoke\b"#, options: .regularExpression) != nil
    }

    /// Intermediate flush during streaming: strip invisible markup, no fallback
    /// (more text may still arrive, so the bubble can go briefly empty).
    private static func stripReplyMarkup(_ text: String) -> String {
        stripToolCallMarkup(from: stripPersonalization(from: text))
    }

    /// Final content for a finished reply: strip markup and, if the model's
    /// whole reply was just a tool-call block (budget exhausted with no text),
    /// replace it with a graceful note instead of an empty bubble.
    private static func finalReply(_ text: String) -> String {
        let cleaned = stripReplyMarkup(text)
        if cleaned.isEmpty, containsToolCallMarkup(text) {
            return L("tool.call.stripped")
        }
        return cleaned
    }

    // MARK: - Full-text search

    /// Case-insensitive search across all session titles + message contents.
    /// Returns results ordered by session recency, then by message order.
    var searchResults: [MessageSearchResult] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var results: [MessageSearchResult] = []
        for session in sessions {
            for message in session.messages where message.role == .user || message.role == .assistant {
                guard message.content.range(of: query, options: [.caseInsensitive]) != nil else {
                    continue
                }
                results.append(MessageSearchResult(
                    id: message.id,
                    sessionID: session.id,
                    sessionTitle: session.title,
                    message: message,
                    snippet: Self.searchSnippet(for: message.content, query: query)
                ))
            }
        }
        return results
    }

    /// Jumps to the message containing a search hit and highlights it briefly.
    func selectSearchResult(_ result: MessageSearchResult) {
        selectSession(id: result.sessionID)
        highlightMessageID = result.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if highlightMessageID == result.id {
                highlightMessageID = nil
            }
        }
    }

    /// Clears the sidebar search query.
    func clearSearch() {
        searchQuery = ""
        highlightMessageID = nil
    }

    /// Builds a short excerpt around the first match of `query` in `content`.
    private static func searchSnippet(for content: String, query: String) -> String {
        let flat = content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let range = flat.range(of: query, options: [.caseInsensitive]) else {
            return String(flat.prefix(90))
        }
        let start = flat.index(range.lowerBound, offsetBy: -35, limitedBy: flat.startIndex)
            ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 70, limitedBy: flat.endIndex)
            ?? flat.endIndex
        var text = String(flat[start..<end])
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return (start > flat.startIndex ? "…" : "") + text + (end < flat.endIndex ? "…" : "")
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