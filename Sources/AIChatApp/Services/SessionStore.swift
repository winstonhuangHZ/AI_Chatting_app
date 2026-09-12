import Foundation
import Dispatch

/// Persists chat sessions (title + full message history) using `UserDefaults`
/// with a JSON-encoded array.
final class SessionStore: ObservableObject {

    // MARK: - Constants

    /// `UserDefaults` key encoding all sessions.
    private static let sessionsKey = "chatSessions"

    /// `UserDefaults` key recording the selected session UUID string.
    private static let activeIDKey = "activeSessionID"

    /// Set after the legacy UserDefaults payload has been migrated, so that
    /// deleting all chats later does not re-import the stale legacy copy.
    private static let migratedFlagKey = "chatSessions.sqliteMigrated.v1"

    /// Set after the FTS index has been built and the database vacuumed once.
    private static let ftsIndexedFlagKey = "chatSessions.ftsIndexed.v1"

    /// Serial queue for the expensive full-history JSON encode + UserDefaults
    /// flush. Encoding 40+ MB of sessions synchronously on the main thread was
    /// the source of UI freezes on every message append/delete; snapshots are
    /// captured on the main thread and written here in order.
    private static let persistQueue = DispatchQueue(
        label: "com.aichat.app.session-persist",
        qos: .utility
    )

    /// Phase-1 SQLite backend (nil ⇒ legacy UserDefaults fallback).
    private let sqlite: SQLiteSessionStore?

    /// True once the FTS index has been built (search falls back until then).
    private(set) var ftsReady = false

    /// Per-session summaries (small; safe to keep fully in memory).
    @Published private(set) var summaries: [UUID: SessionSummary] = [:]

    // MARK: - Published state

    /// When true, persist() is a no-op. Set while the streaming pipeline
    /// repeatedly updates the assistant message so we don't JSON-encode +
    /// disk-write on every 50–100 ms flush (which stalls the main thread).
    var persistPaused = false

    /// All saved sessions, most-recently-created first.
    @Published var sessions: [ChatSession] {
        didSet { persist() }
    }

    /// The session currently open in the chat view.
    @Published var activeSessionID: UUID? {
        didSet {
            UserDefaults.standard.set(
                activeSessionID?.uuidString,
                forKey: Self.activeIDKey
            )
        }
    }

    /// Convenience accessor for the active session object.
    var activeSession: ChatSession? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Initializers

    init() {
        let database = try? SQLiteSessionStore(url: SQLiteSessionStore.defaultURL())
        self.sqlite = database

        let defaults = UserDefaults.standard

        let databaseSessions = database?.loadSessionMetas() ?? []
        if !databaseSessions.isEmpty {
            self.sessions = databaseSessions
            defaults.set(true, forKey: Self.migratedFlagKey)
        } else if database != nil,
                  defaults.bool(forKey: Self.migratedFlagKey) {
            // Migrated before; an empty database means the user deleted all
            // conversations, so do not resurrect the legacy copy.
            self.sessions = []
        } else if let data = defaults.data(forKey: Self.sessionsKey),
                  let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            // First launch on 1.2.0: keep the legacy payload untouched as a
            // rollback copy and migrate it into SQLite in the background.
            let sorted = decoded.sorted { $0.createdAt > $1.createdAt }
            self.sessions = sorted
            if let database {
                Self.persistQueue.async {
                    if database.replaceAll(sorted) {
                        UserDefaults.standard.set(true, forKey: Self.migratedFlagKey)
                    }
                }
            }
        } else {
            self.sessions = []
        }

        if let stored = defaults.string(forKey: Self.activeIDKey),
           let id = UUID(uuidString: stored),
           self.sessions.contains(where: { $0.id == id }) {
            self.activeSessionID = id
        } else {
            self.activeSessionID = self.sessions.first?.id
        }

        if let database {
            for summary in database.loadSummaries() {
                summaries[summary.sessionID] = summary
            }
        }

        // Phase 2.2: move legacy base64 attachments to Application Support
        // files. Runs off the main thread; the legacy UserDefaults payload is
        // untouched, so this is recoverable.
        let attachmentSnapshot = self.sessions
        let databaseForMigration = database
        Self.persistQueue.async {
            let (imagePaths, documentPaths) = Self.externalizeAttachmentFiles(in: attachmentSnapshot)
            guard !imagePaths.isEmpty || !documentPaths.isEmpty else { return }
            DispatchQueue.main.async {
                var changedMessages: [(UUID, UUID)] = []
                for sessionIndex in self.sessions.indices {
                    for messageIndex in self.sessions[sessionIndex].messages.indices {
                        var message = self.sessions[sessionIndex].messages[messageIndex]
                        var changed = false
                        for attachmentIndex in message.attachments.indices
                        where message.attachments[attachmentIndex].filePath == nil {
                            if let path = imagePaths[message.attachments[attachmentIndex].id] {
                                message.attachments[attachmentIndex].filePath = path
                                message.attachments[attachmentIndex].base64Data = ""
                                changed = true
                            }
                        }
                        for documentIndex in message.documentAttachments.indices
                        where message.documentAttachments[documentIndex].filePath == nil {
                            if let path = documentPaths[message.documentAttachments[documentIndex].id] {
                                message.documentAttachments[documentIndex].filePath = path
                                message.documentAttachments[documentIndex].base64Data = ""
                                changed = true
                            }
                        }
                        if changed {
                            let sessionID = self.sessions[sessionIndex].id
                            self.sessions[sessionIndex].messages[messageIndex] = message
                            changedMessages.append((sessionID, message.id))
                        }
                    }
                }
                if !changedMessages.isEmpty {
                    for (sessionID, messageID) in changedMessages {
                        if let message = self.sessions
                            .first(where: { $0.id == sessionID })?
                            .messages.first(where: { $0.id == messageID }) {
                            self.persistMessage(message, in: sessionID)
                        }
                    }
                    if let databaseForMigration {
                        let snapshot = self.sessions
                        Self.persistQueue.async {
                            if databaseForMigration.replaceAll(snapshot) {
                                UserDefaults.standard.set(true, forKey: Self.migratedFlagKey)
                            }
                        }
                    }
                }
            }
        }

        // Phase 2.3: build the FTS index once (and reclaim free pages), then
        // search can query the database instead of scanning every message.
        if let database {
            if defaults.bool(forKey: Self.ftsIndexedFlagKey) {
                ftsReady = true
            } else {
                Self.persistQueue.async {
                    database.rebuildIndexAndCompact()
                    DispatchQueue.main.async {
                        UserDefaults.standard.set(true, forKey: Self.ftsIndexedFlagKey)
                        self.ftsReady = true
                    }
                }
            }
        }
    }

    // MARK: - Session management

    /// Loads one session's message bodies from SQLite on demand.
    @discardableResult
    func loadMessagesIfNeeded(_ sessionID: UUID) -> Bool {
        guard let sqlite,
              let index = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[index].messagesLoaded else { return false }
        let messages = sqlite.loadMessages(sessionID: sessionID)
        sessions[index].messages = messages
        sessions[index].messageCount = messages.count
        sessions[index].messagesLoaded = true
        return true
    }

    /// Loads every session's messages (used before export/import and by the
    /// in-memory search fallback).
    func loadAllMessages() {
        guard let sqlite else { return }
        for index in sessions.indices where !sessions[index].messagesLoaded {
            let messages = sqlite.loadMessages(sessionID: sessions[index].id)
            sessions[index].messages = messages
            sessions[index].messageCount = messages.count
            sessions[index].messagesLoaded = true
        }
    }

    /// Creates a new empty session and makes it active.
    @discardableResult
    func newSession() -> ChatSession {
        let session = ChatSession()
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        persistAllSessionMetas()
        return session
    }

    /// Creates a new personalization-collection session (dedicated collector prompt,
    /// can be turned into a personalization block) and makes it active.
    @discardableResult
    func newPersonalizationCollectionSession() -> ChatSession {
        let session = ChatSession(
            title: "个性化块采集",
            isPersonalizationCollection: true
        )
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        persistAllSessionMetas()
        return session
    }

    /// Deletes a session (by id).
    func delete(_ session: ChatSession) {
        Self.deleteAttachmentFiles(in: session.messages)
        deleteSummary(sessionID: session.id)
        sessions.removeAll { $0.id == session.id }
        deleteSessionRow(session.id)
        persistAllSessionMetas()

        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }

    /// Pins/unpins a session. Pin state is persisted on the session itself;
    /// display ordering is handled by the ViewModel.
    func togglePin(_ session: ChatSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].isPinned.toggle()
        persistSession(sessions[index])
    }

    /// Moves a session into (or out of) a folder.
    func move(_ session: ChatSession, to folderID: UUID?) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].folderID = folderID
        persistSession(sessions[index])
    }

    func move(sessionID: UUID, to folderID: UUID?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].folderID = folderID
        persistSession(sessions[index])
    }

    /// Clears folder membership after a folder is deleted.
    func clearFolder(_ folderID: UUID) {
        for index in sessions.indices where sessions[index].folderID == folderID {
            sessions[index].folderID = nil
            persistSession(sessions[index])
        }
    }

    /// Manual user-provided title/emoji (sidebar edit sheet). Marks the title
    /// as "chosen" so the model stops trying to rename it automatically.
    func applyManualMetadata(
        title: String? = nil,
        emoji: String? = nil,
        in sessionID: UUID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[index].hasModelTitle = true
        }
        if let emoji {
            let cleaned = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[index].emoji = cleaned.isEmpty ? nil : cleaned
        }
        persistSession(sessions[index])
    }

    /// Deletes all sessions.
    func deleteAll() {
        for session in sessions { deleteSummary(sessionID: session.id) }
        for session in sessions {
            Self.deleteAttachmentFiles(in: session.messages)
        }
        sessions.removeAll()
        activeSessionID = nil
        if let sqlite {
            Self.persistQueue.async { sqlite.deleteAll() }
        }
    }

    /// Replaces the entire session list (used when importing a backup).
    func replaceAll(with new: [ChatSession]) {
        cancelPersistPause()
        let externalized = Self.externalizingAttachments(in: new).0
        sessions = externalized
            .map { session -> ChatSession in
                var session = session
                session.messageCount = session.messages.count
                session.messagesLoaded = true
                return session
            }
            .sorted { $0.createdAt > $1.createdAt }
        activeSessionID = sessions.first?.id
        persistPaused = false
        if let sqlite {
            let snapshot = sessions
            Self.persistQueue.async {
                if sqlite.replaceAll(snapshot) {
                    UserDefaults.standard.set(true, forKey: Self.migratedFlagKey)
                }
            }
        }
    }

    /// Cancels any active persistence pause and forces a write.
    private func cancelPersistPause() {
        persistPaused = false
    }

    /// Appends a message to the given session and persists it.
    func appendMessage(_ message: ChatMessage, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        sessions[index].messageCount = sessions[index].messages.count
        sessions[index].autoTitle()
        markSummaryStale(sessionID)
        persistMessage(message, in: sessionID)
        persistSession(sessions[index])
    }

    /// Applies AI-chosen session metadata (first-round `set_session_metadata`
    /// tool): a short title and/or an emoji shown in the sidebar.
    func updateSessionMetadata(emoji: String?, title: String?, in sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let emoji, !emoji.isEmpty {
            sessions[index].emoji = emoji
        }
        if let title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !sessions[index].hasModelTitle {
            sessions[index].title = title
            sessions[index].hasModelTitle = true
        }
        persistSession(sessions[index])
    }

    /// Updates the content of the last assistant message in a session.
    ///
    /// Used by the streaming pipeline to accumulate deltas into the
    /// in-flight assistant reply.
    func updateLastAssistantContent(_ content: String, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].content = content
        persistMessage(sessions[sessionIndex].messages[msgIndex], in: sessionID)
    }

    /// Attaches source references to the last assistant message in a session
    /// (web tools' URLs rendered as the "Sources" card under the reply).
    func updateLastAssistantSources(_ sources: [ChatSource], in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].sources = sources
        persistMessage(sessions[sessionIndex].messages[msgIndex], in: sessionID)
    }

    /// Records the model that produced the last assistant message (info popover).
    func updateLastAssistantModel(_ model: String, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].model = model
        persistMessage(sessions[sessionIndex].messages[msgIndex], in: sessionID)
    }

    /// Records the relay-reported token usage for the last assistant message.
    func updateLastAssistantUsage(_ usage: MessageUsage, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].usage = usage
        persistMessage(sessions[sessionIndex].messages[msgIndex], in: sessionID)
    }

    /// Records the tool-call flow executed while producing the last assistant
    /// message (Agent mode / get_time), for the message-info popover.
    func updateLastAssistantToolFlow(_ flow: [MessageToolCallRecord], in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].toolFlow = flow
        persistMessage(sessions[sessionIndex].messages[msgIndex], in: sessionID)
    }

    /// Records the DeepSeek `reasoning_content` ("thinking") of the last
    /// assistant message so the next request can pass it back (required by
    /// DeepSeek reasoning models for tool-call rounds).
    func updateLastAssistantReasoning(_ reasoning: String, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].reasoningContent = reasoning
        persistMessage(sessions[sessionIndex].messages[msgIndex], in: sessionID)
    }

    /// Deletes a single message (by id) from the given session.
    func deleteMessage(_ message: ChatMessage, in sessionID: UUID) {
        Self.deleteAttachmentFiles(in: [message])
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.removeAll { $0.id == message.id }
        sessions[index].messageCount = max(0, sessions[index].messageCount - 1)
        markSummaryStale(sessionID)
        deleteMessageRow(message.id)
    }

    /// Removes a partially-received assistant message (used when a stream fails
    /// before yielding anything useful).
    func removeLastAssistantMessage(in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant,
              sessions[sessionIndex].messages[msgIndex].content.isEmpty else {
            return
        }
        let removedID = sessions[sessionIndex].messages[msgIndex].id
        Self.deleteAttachmentFiles(in: [sessions[sessionIndex].messages[msgIndex]])
        sessions[sessionIndex].messages.remove(at: msgIndex)
        sessions[sessionIndex].messageCount = sessions[sessionIndex].messages.count
        markSummaryStale(sessionID)
        deleteMessageRow(removedID)
    }

    /// Replaces a user message in place and drops every later message, so the
    /// edited prompt becomes the new end of the conversation.
    func replaceMessageAndRemoveFollowing(
        messageID: UUID,
        with replacement: ChatMessage,
        in sessionID: UUID
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        Self.deleteAttachmentFiles(
            in: Array(sessions[sessionIndex].messages[messageIndex...])
        )
        sessions[sessionIndex].messages.removeSubrange(messageIndex...)
        sessions[sessionIndex].messages.insert(replacement, at: messageIndex)
        sessions[sessionIndex].messageCount = sessions[sessionIndex].messages.count
        markSummaryStale(sessionID)
        persistWholeSessionMessages(sessionID)
        persistSession(sessions[sessionIndex])
    }

    /// Edit-and-resend: replaces the edited user message, drops the old suffix
    /// and appends the assistant placeholder in ONE mutation, so SwiftUI never
    /// renders the intermediate (truncated-but-not-yet-regenerating) layout.
    func replaceUserMessageAndAppendAssistant(
        messageID: UUID,
        replacement: ChatMessage,
        assistant: ChatMessage,
        in sessionID: UUID
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        Self.deleteAttachmentFiles(
            in: Array(sessions[sessionIndex].messages[messageIndex...])
        )
        sessions[sessionIndex].messages.removeSubrange(messageIndex...)
        sessions[sessionIndex].messages.insert(replacement, at: messageIndex)
        sessions[sessionIndex].messages.append(assistant)
        sessions[sessionIndex].messageCount = sessions[sessionIndex].messages.count
        markSummaryStale(sessionID)
        persistWholeSessionMessages(sessionID)
        persistSession(sessions[sessionIndex])
    }

    // MARK: - Assistant answer versions (regenerate branches)

    /// Prepares the last assistant message to receive a regenerated answer while
    /// preserving the previous answer as version 1.
    func prepareAssistantForRegeneration(
        messageID: UUID,
        model: String,
        in sessionID: UUID
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }),
              sessions[sessionIndex].messages[messageIndex].role == .assistant else {
            return
        }
        var message = sessions[sessionIndex].messages[messageIndex]

        if message.versions.isEmpty {
            message.versions = [ChatMessageVersion(message: message)]
        } else if message.activeVersionIndex >= 0,
                  message.activeVersionIndex < message.versions.count {
            message.versions[message.activeVersionIndex] = ChatMessageVersion(message: message)
        }

        message.content = ""
        message.model = model
        message.usage = nil
        message.sources = []
        message.toolFlow = []
        message.reasoningContent = nil
        sessions[sessionIndex].messages[messageIndex] = message
        persistMessage(message, in: sessionID)
    }

    /// Commits the currently-streamed answer as a new version once it finished.
    func finalizeAssistantVersion(
        messageID: UUID,
        in sessionID: UUID
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }),
              sessions[sessionIndex].messages[messageIndex].role == .assistant else {
            return
        }
        var message = sessions[sessionIndex].messages[messageIndex]
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        message.versions.append(ChatMessageVersion(message: message))
        message.activeVersionIndex = message.versions.count - 1
        sessions[sessionIndex].messages[messageIndex] = message
        persistMessage(message, in: sessionID)
    }

    /// Convenience for streaming paths that only know the originating session.
    func finalizeLastAssistantVersion(in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageID = sessions[sessionIndex].messages.last?.id else {
            return
        }
        finalizeAssistantVersion(messageID: messageID, in: sessionID)
    }

    /// Switches the visible assistant answer version.
    func selectAssistantVersion(
        messageID: UUID,
        index: Int,
        in sessionID: UUID
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }),
              index >= 0,
              index < sessions[sessionIndex].messages[messageIndex].versions.count else {
            return
        }
        let version = sessions[sessionIndex].messages[messageIndex].versions[index]
        sessions[sessionIndex].messages[messageIndex].activeVersionIndex = index
        sessions[sessionIndex].messages[messageIndex].content = version.content
        sessions[sessionIndex].messages[messageIndex].timestamp = version.timestamp
        sessions[sessionIndex].messages[messageIndex].model = version.model
        sessions[sessionIndex].messages[messageIndex].usage = version.usage
        sessions[sessionIndex].messages[messageIndex].sources = version.sources
        sessions[sessionIndex].messages[messageIndex].toolFlow = version.toolFlow
        sessions[sessionIndex].messages[messageIndex].reasoningContent = version.reasoningContent
        sessions[sessionIndex].messages[messageIndex].question = version.question
        persistMessage(sessions[sessionIndex].messages[messageIndex], in: sessionID)
    }

    /// Restores the currently selected version after a failed regeneration
    /// (so cancelling/failing never leaves a blank bubble or loses the answer).
    func restoreActiveAssistantVersion(messageID: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        let index = sessions[sessionIndex].messages[messageIndex].activeVersionIndex
        selectAssistantVersion(messageID: messageID, index: index, in: sessionID)
    }

    // MARK: - Agent questions

    // MARK: - Session summaries

    func summary(for sessionID: UUID) -> SessionSummary? {
        summaries[sessionID]
    }

    func saveSummary(_ summary: SessionSummary) {
        summaries[summary.sessionID] = summary
        sqlite?.saveSummary(summary)
    }

    func deleteSummary(sessionID: UUID) {
        summaries.removeValue(forKey: sessionID)
        sqlite?.deleteSummary(sessionID: sessionID)
    }

    /// Cheap local invalidation: any message change makes the summary stale.
    func markSummaryStale(_ sessionID: UUID) {
        guard var summary = summaries[sessionID], summary.status != .stale else { return }
        summary.status = .stale
        summaries[sessionID] = summary
        sqlite?.saveSummary(summary)
    }

    /// Attaches a structured question to an assistant message. The message
    /// content is set to the human-readable question so the wire history stays
    /// coherent without any UI metadata.
    func attachQuestion(_ question: AgentQuestion, to messageID: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        sessions[sessionIndex].messages[messageIndex].question = question
        sessions[sessionIndex].messages[messageIndex].content = question.question
        persistMessage(sessions[sessionIndex].messages[messageIndex], in: sessionID)
    }

    func attachQuestionToLast(_ question: AgentQuestion, in sessionID: UUID) {
        guard let messageID = sessions.first(where: { $0.id == sessionID })?.messages.last?.id else { return }
        attachQuestion(question, to: messageID, in: sessionID)
    }

    /// Marks a question as answered and stores the chosen answer text.
    func answerQuestion(
        messageID: UUID,
        answer: String,
        in sessionID: UUID
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }),
              var question = sessions[sessionIndex].messages[messageIndex].question else {
            return
        }
        question.status = .answered
        question.answer = answer
        question.answeredAt = Date()
        sessions[sessionIndex].messages[messageIndex].question = question
        persistMessage(sessions[sessionIndex].messages[messageIndex], in: sessionID)
    }

    // MARK: - Persistence

    private func persist() {
        // SQLite path uses row-level writes (see persistSession/persistMessage);
        // only the legacy UserDefaults fallback still snapshots everything.
        guard sqlite == nil else { return }
        guard !persistPaused else { return }
        let snapshot = sessions
        Self.persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let defaults = UserDefaults.standard
            defaults.set(data, forKey: Self.sessionsKey)
            defaults.synchronize()
        }
    }

    // MARK: - Row-level SQLite writes

    private func persistSession(_ session: ChatSession) {
        guard let sqlite else { return }
        let order = sessions.firstIndex(where: { $0.id == session.id }) ?? 0
        Self.persistQueue.async {
            sqlite.upsertSession(session, order: order)
        }
    }

    private func persistAllSessionMetas() {
        guard let sqlite else { return }
        let snapshot = sessions
        Self.persistQueue.async {
            for (index, session) in snapshot.enumerated() {
                sqlite.upsertSession(session, order: index)
            }
        }
    }

    private func persistMessage(_ message: ChatMessage, in sessionID: UUID) {
        guard let sqlite,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == message.id })
        else { return }
        Self.persistQueue.async {
            sqlite.upsertMessage(message, sessionID: sessionID, order: messageIndex)
        }
    }

    private func persistLastAssistant(in sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let message = session.messages.last else { return }
        persistMessage(message, in: sessionID)
    }

    private func persistWholeSessionMessages(_ sessionID: UUID) {
        guard let sqlite,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        Self.persistQueue.async {
            sqlite.replaceMessages(sessionID: sessionID, messages: session.messages)
        }
    }

    private func deleteMessageRow(_ id: UUID) {
        guard let sqlite else { return }
        Self.persistQueue.async { sqlite.deleteMessage(id: id) }
    }

    private func deleteSessionRow(_ id: UUID) {
        guard let sqlite else { return }
        Self.persistQueue.async { sqlite.deleteSession(id: id) }
    }

    /// Writes once even if persistence was paused (called when streaming ends).
    func forcePersist() {
        persistPaused = false
        if let sqlite {
            Self.persistQueue.async {
                sqlite.checkpoint()
            }
        } else {
            persist()
        }
    }

    // MARK: - Attachment externalization

    /// FTS-backed search. Nil means the index is not ready (or unavailable) and
    /// the caller should fall back to the in-memory scan.
    func searchMessageIDs(query: String, limit: Int = 200) -> [(messageID: UUID, sessionID: UUID)]? {
        guard ftsReady, let sqlite else { return nil }
        guard let hits = sqlite.searchMessageIDs(query: query, limit: limit) else { return nil }
        return hits.map { (messageID: $0.0, sessionID: $0.1) }
    }

    private static func externalizingAttachments(
        in sessions: [ChatSession]
    ) -> ([ChatSession], Bool) {
        var changed = false
        let migrated = sessions.map { session -> ChatSession in
            var session = session
            session.messages = session.messages.map { message -> ChatMessage in
                var message = message
                message.attachments = message.attachments.map { attachment in
                    let updated = attachment.externalized()
                    if updated.filePath != attachment.filePath { changed = true }
                    return updated
                }
                message.documentAttachments = message.documentAttachments.map { document in
                    let updated = document.externalized()
                    if updated.filePath != document.filePath { changed = true }
                    return updated
                }
                return message
            }
            return session
        }
        return (migrated, changed)
    }

    /// Writes legacy base64 payloads to disk and returns attachment-id → path
    /// mappings, so the main thread can merge them without replacing sessions.
    private static func externalizeAttachmentFiles(
        in sessions: [ChatSession]
    ) -> ([UUID: String], [UUID: String]) {
        var imagePaths: [UUID: String] = [:]
        var documentPaths: [UUID: String] = [:]
        for session in sessions {
            for message in session.messages {
                for attachment in message.attachments where attachment.filePath == nil {
                    if let data = attachment.decodedData,
                       let path = AttachmentStore.store(data, id: attachment.id, filename: attachment.filename) {
                        imagePaths[attachment.id] = path
                    }
                }
                for document in message.documentAttachments where document.filePath == nil {
                    if let data = document.decodedData,
                       let path = AttachmentStore.store(data, id: document.id, filename: document.filename) {
                        documentPaths[document.id] = path
                    }
                }
            }
        }
        return (imagePaths, documentPaths)
    }

    private static func deleteAttachmentFiles(in messages: [ChatMessage]) {
        for message in messages {
            for attachment in message.attachments {
                if let path = attachment.filePath { AttachmentStore.delete(path) }
            }
            for document in message.documentAttachments {
                if let path = document.filePath { AttachmentStore.delete(path) }
            }
        }
    }
}
