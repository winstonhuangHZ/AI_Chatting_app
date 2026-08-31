import SwiftUI
import UniformTypeIdentifiers

/// Main chat pane: top configuration bar, scrollable message list,
/// streaming indicator, and multi-line input bar with image attachments.
///
/// Modern macOS 14+ SwiftUI API:
/// - `TextEditor` + `.onSubmit` for Enter-to-send / Shift+Enter-newline
/// - `ScrollViewReader` for smooth autoscroll during streaming
/// - `ProgressView`, `Label`, `overlay(alignment:)`, `foregroundStyle`
struct ChatView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var configStore: ConfigStore

    /// 全局外观（字体预设 / 字号 / 主题）。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    /// Scroll to the latest message when content updates.
    @State private var lastMessageID: UUID?

    /// 拖拽上传中转桥（消息列表区 drop → 输入栏待发送附件）。
    @StateObject private var dropRouter = ChatDropRouter()

    /// 拖拽文件悬停在聊天面板上时高亮。
    @State private var isDropTargeted = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            TopBarView()

            Divider()

            if let session = chatViewModel.activeSession {
                MessageList(
                    session: session,
                    streamingMessageID: chatViewModel.streamingAssistantID,
                    hasReceivedFirstToken: chatViewModel.hasReceivedFirstToken,
                    highlightMessageID: chatViewModel.highlightMessageID,
                    lastMessageID: $lastMessageID
                )
            } else {
                ContentUnavailableView(
                    L("no.chat.selected"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(L("no.chat.description"))
                )
            }

            Divider()

            // Live token counter + cost estimate for the *next* request —
            // includes history + system prompt + user profile (all re-sent).
            UsageBarView(
                messages: chatViewModel.activeMessages,
                model: configStore.activeConfig?.selectedModel ?? "",
                dynamicPrices: configStore.activeConfig?.modelPrices ?? [:],
                systemPrompt: configStore.activeConfig?.systemPrompt ?? "",
                profileJSON: chatViewModel.userProfileStore.jsonPayload,
                customPrice: configStore.activeConfig?.customPrice,
                cacheUsage: chatViewModel.lastCacheUsage
            )

            InputBarView(
                onSend: { text, attachments, documents in
                    chatViewModel.sendMessage(
                        text,
                        config: configStore.activeConfig,
                        model: configStore.activeConfig?.selectedModel ?? "",
                        attachments: attachments,
                        documents: documents
                    )
                },
                isStreaming: chatViewModel.isStreaming,
                dropRouter: dropRouter
            )
        }
        .background(appearance.chatBackground)
        // 拖拽上传：整个聊天面板都是 drop 目标，转发给输入栏挂载的 handler。
        .dropDestination(for: URL.self) { urls, _ in
            dropRouter.onDrop?(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isDropTargeted = targeted
            }
        }
        // 拖拽悬停提示：虚线框 + 「松手附加」胶囊。
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(appearance.accentColor,
                            style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .overlay {
                        Text(L("attach.drop.hint"))
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(appearance.accentColor.opacity(0.18))
                            .clipShape(Capsule())
                    }
            }
        }
        .onReceive(chatViewModel.$sessions) { sessions in
            if let activeID = chatViewModel.activeSessionID,
               let session = sessions.first(where: { $0.id == activeID }) {
                lastMessageID = session.messages.last?.id
            }
        }
        // Memory-change toast (auto-dismisses after 4s).
        .overlay(alignment: .bottom) {
            if let notice = chatViewModel.memoryNotice {
                MemoryNoticeBanner(notice: notice) {
                    chatViewModel.memoryNotice = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 12)
                .padding(.bottom, 92)
                .id(notice.id)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if chatViewModel.memoryNotice?.id == notice.id {
                        chatViewModel.memoryNotice = nil
                    }
                }
            }
        }
        // Cache-reset toast: shown when the shared profile changed or a message
        // was deleted/regenerated since the last request (both change the
        // byte-identical prefix, so the history cache is reset).
        .overlay(alignment: .bottom) {
            if let notice = chatViewModel.cacheResetNotice {
                CacheResetBanner(reason: notice.reason) {
                    chatViewModel.cacheResetNotice = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 12)
                .padding(.bottom, 128)
                .id(notice.id)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if chatViewModel.cacheResetNotice?.id == notice.id {
                        chatViewModel.cacheResetNotice = nil
                    }
                }
            }
        }
        .animation(.default, value: chatViewModel.memoryNotice)
        .animation(.default, value: chatViewModel.cacheResetNotice)
        // Error banner.
        .overlay(alignment: .top) {
            if let error = chatViewModel.errorMessage {
                ErrorBannerView(message: error) {
                    chatViewModel.clearError()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .id(chatViewModel.errorDismissToken)
            }
        }
        .animation(.default, value: chatViewModel.errorMessage)
    }
}

// MARK: - Memory-change toast

/// Small transient toast shown when the AI added/updated/removed memories.
private struct MemoryNoticeBanner: View {

    /// The memory-change event to display.
    let notice: MemoryNotice

    /// Dismiss action.
    let onDismiss: () -> Void

    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .foregroundStyle(.tint)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var message: String {
        var parts: [String] = []
        if notice.addedCount > 0 {
            parts.append(addedText(notice.addedCount))
        }
        if notice.removedCount > 0 {
            parts.append(removedText(notice.removedCount))
        }
        return parts.joined(separator: " · ")
    }

    private func addedText(_ n: Int) -> String {
        // "Memory added/updated (n)"
        L("memory.added") + " (\(n))"
    }

    private func removedText(_ n: Int) -> String {
        L("memory.removed") + " (\(n))"
    }
}

/// Small transient toast shown when the byte-identical cache prefix changed
/// (shared profile updated, or a message deleted/regenerated), resetting the
/// relay's cache for the affected history.
private struct CacheResetBanner: View {

    /// Why the cache was reset (drives the icon + text).
    let reason: CacheResetNotice.Reason

    /// Dismiss action.
    let onDismiss: () -> Void

    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: reason == .historyEdited ? "trash" : "arrow.clockwise")
                .foregroundStyle(.tint)
            Text(L(reason == .historyEdited ? "cache.reset.history" : "cache.reset.profile"))
                .font(.callout)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}



// MARK: - Top configuration bar

/// Horizontal bar with profile + model pickers and streaming controls.
private struct TopBarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var configStore: ConfigStore

    /// 全局外观（字体预设 / 字号）。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Profile picker
            Picker(L("profile"), selection: $configStore.activeConfigID) {
                ForEach(configStore.configs) { config in
                    Text(config.displayName)
                        .tag(Optional(config.id))
                }
                if configStore.configs.isEmpty {
                    Text(L("no.configs.tag"))
                        .tag(Optional<UUID>.none)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 160)
            .tint(appearance.accentColor)

            // Model picker (populated from the active profile).
            // Multimodal models are marked with 🖼 on the right.
            if let activeConfig = configStore.activeConfig {
                Picker(L("model"), selection: modelPickerBinding(for: activeConfig)) {
                    if activeConfig.availableModels.isEmpty {
                        Text(L("model.empty.tag")).tag("")
                    }
                    ForEach(activeConfig.availableModels, id: \.self) { model in
                        Text(MultimodalSupport.displayName(model)).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 200)
                .tint(appearance.accentColor)
            }

            Spacer()

            // Agent mode toggle (built-in tool calling: web search / calc /
            // time). Off by default so normal chats keep the plain `tools`-free
            // request body (prompt-cache friendly, relay-safe).
            if configStore.activeConfig != nil {
                Toggle(L("agent.mode"), isOn: agentModeBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
                    .tint(appearance.accentColor)
                    .help(L("agent.mode.help"))
            }

            // Generation controls
            if chatViewModel.isStreaming {
                ProgressView().controlSize(.small)
                Button {
                    chatViewModel.cancelStreaming()
                } label: {
                    Label(L("stop"), systemImage: "stop.fill")
                        .font(appearance.fontPreset.font(size: appearance.pointSize))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    chatViewModel.createNewChat()
                } label: {
                    Label(L("new.chat"), systemImage: "square.and.pencil")
                        .font(appearance.fontPreset.font(size: appearance.pointSize))
                }
                .buttonStyle(.bordered)
                .tint(appearance.accentColor)
                .help(L("new.chat.help"))
            }

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help(L("settings.open.help"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Helpers

    /// Writes model selections straight through to the stored profile.
    private func modelPickerBinding(for config: APIServerConfig) -> Binding<String> {
        Binding(
            get: {
                configStore.configs.first(where: { $0.id == config.id })?.selectedModel ?? ""
            },
            set: { newModel in
                guard let index = configStore.configs.firstIndex(where: { $0.id == config.id }) else { return }
                configStore.configs[index].selectedModel = newModel
            }
        )
    }

    /// Agent mode toggle reads/writes the active profile's `toolsEnabled`.
    private var agentModeBinding: Binding<Bool> {
        Binding(
            get: { configStore.activeConfig?.toolsEnabled ?? false },
            set: { newValue in
                guard let id = configStore.activeConfigID,
                      let index = configStore.configs.firstIndex(where: { $0.id == id }) else { return }
                configStore.configs[index].toolsEnabled = newValue
            }
        )
    }
}

// MARK: - Message list

/// Scrollable list of messages with smooth autocroll during streaming.
private struct MessageList: View {

    /// Session being displayed.
    let session: ChatSession

    /// The id of the assistant message currently being streamed.
    let streamingMessageID: UUID?

    /// `true` once streaming has yielded content (drives two-stage indicator).
    let hasReceivedFirstToken: Bool

    /// Message id to scroll to + highlight (jump from the sidebar search).
    let highlightMessageID: UUID?

    /// Binding updated to the newest message id (drives autoscroll).
    @Binding var lastMessageID: UUID?

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(session.messages) { message in
                        MessageBubble(
                            message: message,
                            isStreaming: message.id == streamingMessageID,
                            hasReceivedFirstToken: hasReceivedFirstToken,
                            isHighlighted: message.id == highlightMessageID
                        )
                        .id(message.id)
                    }
                }
                .padding(16)
            }
            // Anchor content growth at the bottom: streaming replies extend
            // below the viewport instead of pushing the window "up"; the
            // system re-anchors smoothly (macOS 14+ `.smooth` easing).
            .defaultScrollAnchor(.bottom)
            .onChange(of: lastMessageID) { _, newID in
                if let newID {
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: highlightMessageID) { _, newID in
                if let newID {
                    withAnimation(.smooth(duration: 0.3)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let id = session.messages.last?.id {
                    withAnimation(.smooth(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Message bubble

/// Renders a single chat message as a bubble with role-appropriate styling
/// and inline image previews for attachments.
///
/// Overlap fix: `.fixedSize(horizontal: false, vertical: true)` on the outer
/// container prevents LazyVStack from collapsing a bubble's width/height
/// while Markdown is re-rendering during streaming — the previous cause of
/// overlapping (a new message appearing on top of an older one).
private struct MessageBubble: View {

    /// Message to display.
    let message: ChatMessage

    /// `true` while this assistant message is being streamed.
    let isStreaming: Bool

    /// `true` once streaming has yielded the first content token.
    let hasReceivedFirstToken: Bool

    /// `true` when this message is the sidebar-search highlight target.
    let isHighlighted: Bool

    /// `true` while the generation-metadata popover is open.
    @State private var showDetail = false

    /// `true` while the DeepSeek "thinking" section is expanded.
    @State private var showReasoning = false

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatar
            }

            // 列内对齐跟随角色：assistant 靠左（头像在左），user 靠右（头像在右）。
            // 元信息行（You + 时间）与图片/文档附件也随之对齐，不再漂到最左边。
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(roleLabel).font(.caption).foregroundStyle(.secondary)
                    // Per-message send/receive time: persisted with the message
                    // (JSON `timestamp`) but never sent to the API, so prompt
                    // caching is unaffected.
                    Text(message.timestamp.formatted(date: .numeric, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help(message.timestamp.formatted(date: .complete, time: .standard))

                    if message.role == .assistant {
                        Button {
                            showDetail.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help(L("detail.help"))
                        .popover(isPresented: $showDetail) {
                            MessageDetailView(message: message)
                        }
                    }
                }

                // Image attachments preview (user messages).
                if !message.attachments.isEmpty {
                    attachmentGrid
                }

                // Document (PDF) attachments preview (user messages).
                if !message.documentAttachments.isEmpty {
                    documentGrid
                }

                // Collapsed "thinking" section (DeepSeek reasoning models).
                if message.role == .assistant,
                   let reasoning = message.reasoningContent,
                   !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    reasoningSection(reasoning)
                }

                if !contentDisplay.isEmpty {
                    if message.role == .assistant {
                        MarkdownText(text: message.content, fontSize: nil)
                            // Inner: let the markdown breathe to the full row.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bubbleBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            // Outer cap so long tables don't stretch the app.
                            .frame(maxWidth: 620,
                                   alignment: message.role == .user ? .trailing : .leading)
                            // Never compress bubble height while streaming.
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(contentDisplay)
                            .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                            .foregroundStyle(appearance.userBubbleTextColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bubbleBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(maxWidth: 620,
                                   alignment: message.role == .user ? .trailing : .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isStreaming {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        // Before the first token: "Waiting for response…";
                        // once tokens flow: "Generating…". Both render modes
                        // (streaming & non-streaming render) use SSE transport,
                        // so this two-stage indicator applies to both.
                        Text(L(hasReceivedFirstToken ? "generating" : "generating.waiting"))
                            .appearanceFont(appearance.fontPreset, size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }

                // Sources card below AI replies (Agent mode web references).
                if message.role == .assistant && !isStreaming && !message.sources.isEmpty {
                    sourcesCard
                        .padding(.top, 2)
                }

                // Quick actions below AI messages: Retry / Copy / Delete.
                if message.role == .assistant && !isStreaming {
                    messageActionBar
                }
            }

            if message.role == .user {
                avatar
            }
        }
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
        // KEY FIX: prevent the whole bubble from being squeezed into a
        // zero-height row by LazyVStack while its Markdown re-lays out.
        .fixedSize(horizontal: false, vertical: true)
        // Search-result highlight (from the sidebar full-text search).
        .padding(3)
        .background(isHighlighted ? appearance.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        // Right-click actions: copy / delete.
        .contextMenu {
            Button {
                chatViewModel.copyMessage(message)
            } label: {
                Label(L("msg.copy"), systemImage: "doc.on.doc")
            }
            .disabled(message.content.isEmpty)

            Divider()

            Button(role: .destructive) {
                chatViewModel.deleteMessage(message)
            } label: {
                Label(L("msg.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Sources card

    /// "📎 来源" card listing the web references collected from web_search /
    /// web_fetch during the tool loop. Clickable links open in the browser.
    @ViewBuilder
    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("sources.title"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(message.sources) { source in
                Link(destination: Self.sourceURL(source.url)) {
                    HStack(spacing: 6) {
                        Image(systemName: source.url.hasPrefix("file://") ? "doc" : "link")
                            .font(.system(size: 10))
                            .foregroundStyle(appearance.accentColor)
                        Text(source.title.isEmpty ? source.url : source.title)
                            .font(.system(size: 11))
                            .foregroundStyle(appearance.accentColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                .help(source.url)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .frame(maxWidth: 620, alignment: .leading)
    }

    private static func sourceURL(_ string: String) -> URL {
        // Produced files come through as file:// URLs (compile_latex etc.).
        if string.hasPrefix("file://") {
            return URL(string: string) ?? URL(string: "https://")!
        }
        return URL(string: string) ?? URL(string: "https://")!
    }

    // MARK: - Quick action bar (below assistant messages)

    @ViewBuilder
    private var messageActionBar: some View {
        HStack(spacing: 8) {
            actionButton(
                title: L("msg.retry"),
                systemImage: "arrow.clockwise",
                help: L("msg.retry")
            ) {
                chatViewModel.retryMessage(message)
            }

            actionButton(
                title: L("msg.copy"),
                systemImage: "doc.on.doc",
                help: L("msg.copy")
            ) {
                chatViewModel.copyMessage(message)
            }
            .disabled(message.content.isEmpty)

            actionButton(
                title: L("msg.delete"),
                systemImage: "trash",
                help: L("msg.delete")
            ) {
                chatViewModel.deleteMessage(message)
            }
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(appearance.fontPreset.font(size: 10))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Attachment grid

    private var attachmentGrid: some View {
        HStack(spacing: 6) {
            ForEach(message.attachments) { attachment in
                AttachmentThumbnail(attachment: attachment)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// Document (PDF) attachments: file icon + name + page count.
    private var documentGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.documentAttachments) { document in
                HStack(spacing: 6) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(document.filename)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if document.pageCount > 0 {
                            Text(L("pdf.pages", document.pageCount))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        // 用户消息靠右：限宽避免文档卡片横贯整行、与右对齐的气泡脱节。
        .frame(maxWidth: 380, alignment: .trailing)
    }

    // MARK: - Reasoning ("thinking") section

    /// Collapsible view of a reasoning model's thinking text.
    ///
    /// The text is persisted on the message (and passed back to the API on tool
    /// rounds, which DeepSeek requires) — this just surfaces it, collapsed by
    /// default so it never competes with the answer.
    @ViewBuilder
    private func reasoningSection(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    showReasoning.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("💭 \(L("reasoning.title"))")
                        .font(.caption)
                    Text(L("reasoning.chars", reasoning.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("reasoning.help"))

            if showReasoning {
                Text(reasoning)
                    .appearanceFont(appearance.fontPreset, size: max(appearance.pointSize - 1.5, 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.07))
                    )
                    .overlay(alignment: .leading) {
                        // Left rule marks it as "meta" content, not the answer.
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(appearance.accentColor.opacity(0.45))
                            .frame(width: 3)
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 2)
    }


    // MARK: - Derived

    private var roleLabel: String {
        switch message.role {
        case .user: return L("you")
        case .assistant: return L("assistant")
        case .system: return L("system")
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return appearance.userBubbleColor
        case .assistant:
            return appearance.assistantBubbleColor
        case .system:
            return Color(nsColor: .selectedControlColor).opacity(0.4)
        }
    }

    private var contentDisplay: String {
        // Non-streaming render mode: bubble content stays empty while streaming
        // (full reply written once at the end), so no "…" placeholder needed.
        // Streaming render mode fills content progressively (throttled), so the
        // "…" fallback only applies when there is genuinely no content yet.
        message.content.isEmpty && isStreaming ? "" : message.content
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
            .font(.title3)
            .foregroundStyle(message.role == .user ? appearance.accentColor : .purple)
            .frame(width: 28, height: 28)
    }
}

// MARK: - Message detail popover

/// Generation metadata for an assistant reply: model, exact send/receive time,
/// relay-reported token usage and the tool-call flow (Agent mode / get_time).
///
/// All data comes from fields persisted on the message itself — none of it is
/// ever serialized into the API payload, so prompt caching is unaffected.
private struct MessageDetailView: View {
    let message: ChatMessage

    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("detail.title"), systemImage: "info.circle")
                .font(.headline)

            detailRow(L("detail.role"), roleLabel)
            detailRow(L("detail.time"),
                      message.timestamp.formatted(date: .complete, time: .standard))

            if let model = message.model, !model.isEmpty {
                detailRow(L("detail.model"), model)
            }

            if let usage = message.usage {
                Divider()
                Label(L("detail.tokens"), systemImage: "number")
                    .font(.subheadline.weight(.semibold))
                if let p = usage.promptTokens {
                    detailRow(L("detail.tokens.input"), TokenUsage.formatCount(p))
                }
                if let c = usage.completionTokens {
                    detailRow(L("detail.tokens.output"), TokenUsage.formatCount(c))
                }
                if let hit = usage.cacheHitTokens, let miss = usage.cacheMissTokens {
                    let total = hit + miss
                    let ratio = total > 0 ? String(format: "%.0f%%", Double(hit) / Double(total) * 100) : "–"
                    detailRow(L("detail.tokens.cache"),
                              "\(TokenUsage.formatCount(hit)) / \(TokenUsage.formatCount(miss))  (\(ratio))")
                }
            }

            if !message.toolFlow.isEmpty {
                Divider()
                Label(L("detail.tools"), systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(message.toolFlow.enumerated()), id: \.offset) { index, record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(record.name)")
                            .font(.caption.weight(.semibold))
                        if !record.arguments.isEmpty {
                            Text(record.arguments)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        if !record.resultPreview.isEmpty {
                            Text(record.resultPreview)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if message.model == nil && message.usage == nil && message.toolFlow.isEmpty {
                Text(L("detail.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return L("you")
        case .assistant: return L("assistant")
        case .system: return L("system")
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Attachment thumbnail


// MARK: - Attachment thumbnail

private struct AttachmentThumbnail: View {
    let attachment: ImageAttachment

    var body: some View {
        if let data = attachment.decodedData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 180, maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                )
        } else {
            Text("🖼 \(attachment.filename)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Usage bar

/// Bottom status bar: live token counts + cost estimate.
private struct UsageBarView: View {
    let messages: [ChatMessage]
    let model: String
    let dynamicPrices: [String: ModelPrice]
    let systemPrompt: String
    let profileJSON: String?
    let customPrice: CustomPrice?

    /// Relay-reported cache hit/miss for the last completed request.
    let cacheUsage: StreamUsage?

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    private var summary: (input: Int, output: Int, freshInput: Int) {
        TokenUsage.summarize(messages, systemPrompt: systemPrompt, profileJSON: profileJSON)
    }

    /// `true` when the relay returned a real `usage` for the last request.
    private var hasRealUsage: Bool {
        cacheUsage?.promptTokens != nil && cacheUsage?.completionTokens != nil
    }

    /// Tokens shown in the bar: the relay-reported REAL usage when available,
    /// otherwise the local estimate for the next request.
    private var displayInput: Int {
        hasRealUsage ? (cacheUsage?.promptTokens ?? 0) : summary.input
    }

    private var displayOutput: Int {
        hasRealUsage ? (cacheUsage?.completionTokens ?? 0) : summary.output
    }

    private var costEstimate: TokenUsage.CostEstimate? {
        TokenUsage.estimatedCost(
            model: model,
            inputTokens: displayInput,
            outputTokens: displayOutput,
            freshTokens: summary.freshInput,
            dynamicPrices: dynamicPrices,
            customPrice: customPrice
        )
    }

    private var priceUnknown: Bool {
        !model.isEmpty
            && TokenUsage.pricing(
                for: model,
                dynamicPrices: dynamicPrices,
                customPrice: customPrice
            ) == nil
    }

    private var usingCustomPrice: Bool {
        customPrice?.isValid == true
    }

    private var usingDynamicPrice: Bool {
        guard let price = dynamicPrices[model] else { return false }
        return price.isValid
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(L("usage.tokens",
                   TokenUsage.formatCount(displayInput),
                   TokenUsage.formatCount(displayOutput)))
                .font(.caption).foregroundStyle(.secondary)
                .help(L(hasRealUsage ? "usage.tokens.real" : "usage.tokens.estimate"))

            if let estimate = costEstimate {
                Text("≈ \(TokenUsage.formatCost(estimate.full))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L("usage.cost.full"))
                // Realistic estimate: the repeatedly re-sent context (history
                // prefix) hits the cache at the cached-input rate; only the
                // newest user message is billed at the full input rate.
                if let blended = estimate.blended, blended < estimate.full {
                    Text(L("usage.cost.cached", TokenUsage.formatCost(blended)))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(L("usage.cost.cached.help"))
                } else if let cached = estimate.cached, cached < estimate.full {
                    Text(L("usage.cost.cached", TokenUsage.formatCost(cached)))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(L("usage.cost.cached.help"))
                }
            }

            if priceUnknown {
                Text(L("price.unknown"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if usingCustomPrice {
                Text(L("custom.price.badge"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if usingDynamicPrice {
                Text(L("relay.price"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            // Relay-reported prefix-cache hit rate for the last request
            // (DeepSeek `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`).
            if let usage = cacheUsage, let ratio = usage.cacheHitRatio {
                Text(L("usage.cache.hit", Int((ratio * 100).rounded())))
                    .font(.caption)
                    .foregroundStyle(ratio >= 0.5 ? Color.secondary : Color.orange)
                    .help(L("usage.cache.detail", usage.cacheHitTokens ?? 0, usage.cacheMissTokens ?? 0))
            }

            if !messages.isEmpty {
                Text(L("msg.count", messages.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 拖拽文件的中转桥：把整个聊天面板（消息列表区）收到的文件 drop 转发给
/// 输入栏的待发送附件状态。输入栏出现时注册自己的 handler，消失时清空。
private final class ChatDropRouter: ObservableObject {
    /// 当前输入栏注册的 drop 处理器（nil = 无输入栏）。
    var onDrop: (([URL]) -> Void)?
}

// MARK: - Input bar

/// Multi-line input with image attachments:
/// - `TextEditor`: Enter sends, Shift+Enter inserts a newline (native).
/// - 🖼 button opens NSOpenPanel to attach images.
/// - Thumbnail previews can be removed before sending.
private struct InputBarView: View {

    let onSend: (String, [ImageAttachment], [DocumentAttachment]) -> Void
    let isStreaming: Bool

    /// 拖拽上传中转桥（父级聊天面板的 drop 转发到这里）。
    let dropRouter: ChatDropRouter

    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    @State private var draft = ""
    @State private var pendingAttachments: [ImageAttachment] = []
    @State private var pendingDocuments: [DocumentAttachment] = []
    @FocusState private var isFocused: Bool

    /// 支持直接拖入的图片扩展名（与上传按钮一致）。
    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Attachment preview row (images + PDFs).
            if !pendingAttachments.isEmpty || !pendingDocuments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pendingAttachments) { attachment in
                        PendingAttachmentChip(attachment: attachment) {
                            removeAttachment(attachment)
                        }
                    }
                    ForEach(pendingDocuments) { document in
                        PendingDocumentChip(document: document) {
                            removeDocument(document)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    pickImages()
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 14))
                        // 固定框 + 居中：不同 SF Symbol 自带高度基准不同，
                        // 不套框时两个按钮视觉上会上下错位。
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(L("attach.image"))

                Button {
                    pickPDFs()
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(L("attach.pdf"))

                TextEditor(text: $draft)
                    .font(appearance.fontPreset.font(size: appearance.pointSize))
                    .frame(minHeight: 40, maxHeight: 120)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .onSubmit {
                        // Enter alone sends; Shift+Enter produces a newline
                        // natively in TextEditor and does NOT trigger onSubmit.
                        onSubmit()
                    }

                Button {
                    onSubmit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(isSendDisabled ? Color.gray : appearance.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(isSendDisabled)
                .help(L("send"))
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        // 挂载拖拽处理器：整个聊天面板的 drop 通过 router 到这里。
        .onAppear {
            dropRouter.onDrop = { urls in
                handleDropped(urls)
            }
        }
        .onDisappear {
            if dropRouter.onDrop != nil {
                dropRouter.onDrop = nil
            }
        }
    }

    private var isSendDisabled: Bool {
        let textEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isStreaming || (textEmpty && pendingAttachments.isEmpty && pendingDocuments.isEmpty)
    }

    private func onSubmit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false || !pendingAttachments.isEmpty || !pendingDocuments.isEmpty else { return }
        guard !isStreaming else { return }

        let attachments = pendingAttachments
        let documents = pendingDocuments
        draft = ""
        pendingAttachments = []
        pendingDocuments = []
        onSend(text, attachments, documents)
    }

    private func removeAttachment(_ attachment: ImageAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    private func removeDocument(_ document: DocumentAttachment) {
        pendingDocuments.removeAll { $0.id == document.id }
    }

    // MARK: - 附件添加（按钮选择与拖拽共用）

    /// 拖入的文件统一入口：图片/PDF 分别进入待发送列表，其余忽略。
    private func handleDropped(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                addImage(from: url)
            } else if ext == "pdf" {
                addPDF(from: url)
            }
        }
    }

    private func addImage(from url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        guard data.count <= 10 * 1024 * 1024 else { return } // cap 10MB
        let mime = Self.mimeType(for: url.pathExtension)
        pendingAttachments.append(
            ImageAttachment(
                filename: url.lastPathComponent,
                mimeType: mime,
                base64Data: data.base64EncodedString()
            )
        )
    }

    private func addPDF(from url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        // PDFs get a larger cap than images (documents are heavier).
        guard data.count <= 30 * 1024 * 1024 else { return } // cap 30MB
        let pages = PDFProcessor.pageCount(from: data)
        guard pages > 0 else { return } // invalid / non-PDF
        pendingDocuments.append(
            DocumentAttachment(
                filename: url.lastPathComponent,
                mimeType: "application/pdf",
                base64Data: data.base64EncodedString(),
                pageCount: pages
            )
        )
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.title = L("attach.image")
        panel.prompt = L("attach.image")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Modern macOS 12+ API: build UTTypes from extensions (avoids the
        // deprecated `allowedFileTypes`).
        panel.allowedContentTypes = Self.imageExtensions
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            addImage(from: url)
        }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "bmp":  return "image/bmp"
        case "tiff": return "image/tiff"
        default:     return "image/png"
        }
    }

    private func pickPDFs() {
        let panel = NSOpenPanel()
        panel.title = L("attach.pdf")
        panel.prompt = L("attach.pdf")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pdf")]
            .compactMap { $0 }

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            addPDF(from: url)
        }
    }
}

// MARK: - Pending attachment chip

private struct PendingAttachmentChip: View {
    let attachment: ImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let data = attachment.decodedData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(3)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Pending document chip

private struct PendingDocumentChip: View {
    let document: DocumentAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(document.filename)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if document.pageCount > 0 {
                    Text(L("pdf.pages", document.pageCount))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 120)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(4)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Error banner

struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        }
    }
}