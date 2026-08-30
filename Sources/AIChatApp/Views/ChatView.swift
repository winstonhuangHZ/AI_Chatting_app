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
                customPrice: configStore.activeConfig?.customPrice
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
                isStreaming: chatViewModel.isStreaming
            )
        }
        .background(appearance.chatBackground)
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
        .animation(.default, value: chatViewModel.memoryNotice)
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
            .onChange(of: lastMessageID) { _, newID in
                if let newID {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: highlightMessageID) { _, newID in
                if let newID {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let id = session.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
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

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(roleLabel).font(.caption).foregroundStyle(.secondary)
                    Text(message.timestamp, style: .time)
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                // Image attachments preview (user messages).
                if !message.attachments.isEmpty {
                    attachmentGrid
                }

                // Document (PDF) attachments preview (user messages).
                if !message.documentAttachments.isEmpty {
                    documentGrid
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

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    private var summary: (input: Int, output: Int) {
        TokenUsage.summarize(messages, systemPrompt: systemPrompt, profileJSON: profileJSON)
    }

    private var costEstimate: TokenUsage.CostEstimate? {
        TokenUsage.estimatedCost(
            model: model,
            inputTokens: summary.input,
            outputTokens: summary.output,
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
                   TokenUsage.formatCount(summary.input),
                   TokenUsage.formatCount(summary.output)))
                .font(.caption).foregroundStyle(.secondary)

            if let estimate = costEstimate {
                Text("≈ \(TokenUsage.formatCost(estimate.full))")
                    .font(.caption).foregroundStyle(.secondary)
                if let cached = estimate.cached, cached < estimate.full {
                    Text(L("usage.cost.cached", TokenUsage.formatCost(cached)))
                        .font(.caption).foregroundStyle(.secondary)
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

// MARK: - Input bar

/// Multi-line input with image attachments:
/// - `TextEditor`: Enter sends, Shift+Enter inserts a newline (native).
/// - 🖼 button opens NSOpenPanel to attach images.
/// - Thumbnail previews can be removed before sending.
private struct InputBarView: View {

    let onSend: (String, [ImageAttachment], [DocumentAttachment]) -> Void
    let isStreaming: Bool

    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    @State private var draft = ""
    @State private var pendingAttachments: [ImageAttachment] = []
    @State private var pendingDocuments: [DocumentAttachment] = []
    @FocusState private var isFocused: Bool

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
                }
                .buttonStyle(.borderless)
                .help(L("attach.image"))

                Button {
                    pickPDFs()
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14))
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

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.title = L("attach.image")
        panel.prompt = L("attach.image")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Modern macOS 12+ API: build UTTypes from extensions (avoids the
        // deprecated `allowedFileTypes`).
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.count > 10 * 1024 * 1024 { continue } // cap 10MB
            let mime = Self.mimeType(for: url.pathExtension)
            pendingAttachments.append(
                ImageAttachment(
                    filename: url.lastPathComponent,
                    mimeType: mime,
                    base64Data: data.base64EncodedString()
                )
            )
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
            guard let data = try? Data(contentsOf: url) else { continue }
            // PDFs get a larger cap than images (documents are heavier).
            if data.count > 30 * 1024 * 1024 { continue } // cap 30MB
            let pages = PDFProcessor.pageCount(from: data)
            guard pages > 0 else { continue } // invalid / non-PDF
            pendingDocuments.append(
                DocumentAttachment(
                    filename: url.lastPathComponent,
                    mimeType: "application/pdf",
                    base64Data: data.base64EncodedString(),
                    pageCount: pages
                )
            )
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