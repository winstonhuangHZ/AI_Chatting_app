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
                profileJSON: chatViewModel.userProfileStore.jsonPayload
            )

            InputBarView(
                onSend: { text, attachments in
                    chatViewModel.sendMessage(
                        text,
                        config: configStore.activeConfig,
                        model: configStore.activeConfig?.selectedModel ?? "",
                        attachments: attachments
                    )
                },
                isStreaming: chatViewModel.isStreaming
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(chatViewModel.$sessions) { sessions in
            if let activeID = chatViewModel.activeSessionID,
               let session = sessions.first(where: { $0.id == activeID }) {
                lastMessageID = session.messages.last?.id
            }
        }
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

// MARK: - Top configuration bar

/// Horizontal bar with profile + model pickers and streaming controls.
private struct TopBarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var configStore: ConfigStore

    /// 全局外观（字体预设 / 字号）。
    @EnvironmentObject private var appearance: AppearanceStore

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
}

// MARK: - Message list

/// Scrollable list of messages with smooth autocroll during streaming.
private struct MessageList: View {

    /// Session being displayed.
    let session: ChatSession

    /// The id of the assistant message currently being streamed.
    let streamingMessageID: UUID?

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
                            isStreaming: message.id == streamingMessageID
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

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var chatViewModel: ChatViewModel

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
                        Text(L("generating"))
                            .appearanceFont(appearance.fontPreset, size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
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
            return Color.accentColor.opacity(0.15)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor)
        case .system:
            return Color(nsColor: .selectedControlColor).opacity(0.4)
        }
    }

    private var contentDisplay: String {
        message.content.isEmpty && isStreaming ? "…" : message.content
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
            .font(.title3)
            .foregroundStyle(message.role == .user ? Color.accentColor : .purple)
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

    private var summary: (input: Int, output: Int) {
        TokenUsage.summarize(messages, systemPrompt: systemPrompt, profileJSON: profileJSON)
    }

    private var estimatedCost: Double? {
        TokenUsage.estimatedCost(
            model: model,
            inputTokens: summary.input,
            outputTokens: summary.output,
            dynamicPrices: dynamicPrices
        )
    }

    private var priceUnknown: Bool {
        !model.isEmpty && TokenUsage.prices(for: model, dynamicPrices: dynamicPrices) == nil
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

            if let cost = estimatedCost {
                Text("≈ \(TokenUsage.formatCost(cost))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if priceUnknown {
                Text(L("price.unknown"))
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

    let onSend: (String, [ImageAttachment]) -> Void
    let isStreaming: Bool

    @EnvironmentObject private var appearance: AppearanceStore

    @State private var draft = ""
    @State private var pendingAttachments: [ImageAttachment] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Attachment preview row.
            if !pendingAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pendingAttachments) { attachment in
                        PendingAttachmentChip(attachment: attachment) {
                            removeAttachment(attachment)
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
                        .foregroundStyle(isSendDisabled ? Color.gray : Color.accentColor)
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
        return isStreaming || (textEmpty && pendingAttachments.isEmpty)
    }

    private func onSubmit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false || !pendingAttachments.isEmpty else { return }
        guard !isStreaming else { return }

        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        onSend(text, attachments)
    }

    private func removeAttachment(_ attachment: ImageAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
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