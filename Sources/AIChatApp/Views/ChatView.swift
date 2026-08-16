import SwiftUI
import AppKit

/// Main chat pane: top configuration bar, scrollable message list,
/// streaming indicator, and multi-line input bar with image attachments.
///
/// Uses only macOS 10.15-compatible SwiftUI API — no SF Symbols, no `if let`
/// inside ViewBuilders, explicit `self.` in closures (Swift 5.2 rules).
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

            if self.chatViewModel.activeSession != nil {
                MessageList(
                    session: self.chatViewModel.activeSession!,
                    streamingMessageID: self.chatViewModel.streamingAssistantID,
                    lastMessageID: self.$lastMessageID
                )
            } else {
                emptyStateView
            }

            Divider()

            // Live token counter + cost estimate for the active conversation.
            UsageBarView(
                messages: self.chatViewModel.activeMessages,
                model: self.configStore.activeConfig?.selectedModel ?? "",
                dynamicPrices: self.configStore.activeConfig?.modelPrices ?? [:]
            )

            InputBarView(
                onSend: { text, attachments in
                    self.chatViewModel.sendMessage(
                        text,
                        config: self.configStore.activeConfig,
                        model: self.configStore.activeConfig?.selectedModel ?? "",
                        attachments: attachments
                    )
                },
                isStreaming: self.chatViewModel.isStreaming
            )
        }
        .background(Color(NSColor.textBackgroundColor))
        .onReceive(self.chatViewModel.$sessions) { sessions in
            // Track the newest message id for auto-scroll.
            if let activeID = self.chatViewModel.activeSessionID,
               let session = sessions.first(where: { $0.id == activeID }) {
                self.lastMessageID = session.messages.last?.id
            }
        }
        // Error banner: ZStack-based (overlay(alignment:) is macOS 12+).
        .overlay(
            VStack {
                if self.chatViewModel.errorMessage != nil {
                    ErrorBannerView(
                        message: self.chatViewModel.errorMessage!,
                        onDismiss: {
                            self.chatViewModel.clearError()
                        }
                    )
                    .id(self.chatViewModel.errorDismissToken)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    Spacer()
                }
            },
            alignment: .top
        )
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("💬")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Chat Selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Choose a chat from the sidebar or create a new one.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Top configuration bar

/// Horizontal bar with profile + model pickers and streaming controls.
private struct TopBarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var configStore: ConfigStore

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Profile picker
            Picker("Profile", selection: self.$configStore.activeConfigID) {
                ForEach(self.configStore.configs) { config in
                    Text(config.displayName)
                        .tag(Optional(config.id))
                }
                if self.configStore.configs.isEmpty {
                    Text("No profile — add in Settings (⌘,)")
                        .tag(Optional<UUID>.none)
                }
            }
            .frame(minWidth: 160)

            // Model picker (populated from the active profile).
            // Multimodal models are marked with 🖼.
            if self.configStore.activeConfig != nil {
                self.modelPicker
            }

            Spacer()

            // Generation controls (Text-based; no ProgressView for 10.15)
            if self.chatViewModel.isStreaming {
                Text("⏳ Generating…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Button(action: {
                    self.chatViewModel.cancelStreaming()
                }) {
                    Text("⏹ Stop")
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderedButtonStyle())
            } else {
                Button(action: {
                    self.chatViewModel.createNewChat()
                }) {
                    Text("✏️ New Chat")
                }
                .buttonStyle(BorderedButtonStyle())
            }

            // Settings accessor (gear button)
            Button(action: {
                NotificationCenter.default.post(
                    name: .showSettingsNotification,
                    object: nil
                )
            }) {
                Text("⚙️")
            }
            .buttonStyle(BorderedButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    /// Model picker bound to the active profile's selection. Vision-capable
    /// models are labelled with a 🖼 prefix via `MultimodalSupport`.
    private var modelPicker: some View {
        let config = self.configStore.activeConfig!
        let selection = self.modelPickerBinding(for: config)
        return Picker("Model", selection: selection) {
            if config.availableModels.isEmpty {
                Text("No models — fetch in Settings").tag("")
            }
            ForEach(config.availableModels, id: \.self) { model in
                Text(MultimodalSupport.displayName(model)).tag(model)
            }
        }
        .frame(minWidth: 200)
    }

    /// Writes model selections straight through to the stored profile.
    private func modelPickerBinding(for config: APIServerConfig) -> Binding<String> {
        Binding(
            get: {
                self.configStore.configs.first(where: { $0.id == config.id })?.selectedModel ?? ""
            },
            set: { newModel in
                guard let index = self.configStore.configs.firstIndex(where: { $0.id == config.id }) else { return }
                self.configStore.configs[index].selectedModel = newModel
            }
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when the user clicks the gear icon; AppDelegate opens Settings.
    static let showSettingsNotification = Notification.Name("AIChatShowSettings")
}

// MARK: - Message list

/// Scrollable list of messages. Renders text plus any image attachments.
private struct MessageList: View {

    /// Session being displayed.
    let session: ChatSession

    /// The id of the assistant message currently being streamed.
    let streamingMessageID: UUID?

    /// Binding updated to the newest message id (drives autoscroll).
    @Binding var lastMessageID: UUID?

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(self.session.messages) { message in
                    MessageBubble(
                        message: message,
                        isStreaming: message.id == self.streamingMessageID
                    )
                    .id(message.id)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Message bubble

/// Renders a single chat message as a bubble with role-appropriate styling
/// and inline image previews for attachments.
private struct MessageBubble: View {

    /// Message to display.
    let message: ChatMessage

    /// `true` while this assistant message is being streamed.
    let isStreaming: Bool

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if self.message.role == .assistant {
                Text("✨")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.roleLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(self.timeString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Image attachments preview (user messages).
                if !self.message.attachments.isEmpty {
                    self.attachmentGrid
                }

                if !self.contentDisplay.isEmpty {
                    Text(self.contentDisplay)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(self.bubbleBackground)
                        .cornerRadius(10)
                        .frame(maxWidth: 620, alignment: self.message.role == .user ? .trailing : .leading)
                }

                if self.isStreaming {
                    Text("● Generating…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }

            if self.message.role == .user {
                Text("👤")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: self.message.role == .user ? .trailing : .leading)
    }

    // MARK: - Attachment grid

    /// Horizontal row of image thumbnails (max width 200 each).
    private var attachmentGrid: some View {
        HStack(spacing: 6) {
            ForEach(self.message.attachments) { attachment in
                AttachmentThumbnail(attachment: attachment)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Derived content

    private var roleLabel: String {
        switch self.message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }

    /// 10.15-safe time formatting (Text(date, style: .time) is 11+).
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self.message.timestamp)
    }

    private var bubbleBackground: Color {
        switch self.message.role {
        case .user:
            return Color.accentColor.opacity(0.15)
        case .assistant:
            return Color(NSColor.controlBackgroundColor)
        case .system:
            return Color(NSColor.selectedControlColor).opacity(0.4)
        }
    }

    private var contentDisplay: String {
        self.message.content.isEmpty && self.isStreaming
            ? "…"
            : self.message.content
    }
}

// MARK: - Attachment thumbnail

/// Renders a decoded base64 image, or a placeholder when decoding fails.
private struct AttachmentThumbnail: View {

    /// Attachment to display.
    let attachment: ImageAttachment

    // MARK: - Body

    @ViewBuilder var body: some View {
        // Old ViewBuilder has no `if let` support — use if != nil + force unwrap.
        if self.attachment.decodedData != nil && NSImage(data: self.attachment.decodedData!) != nil {
            Image(nsImage: NSImage(data: self.attachment.decodedData!)!)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 180, maxHeight: 140)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                )
        } else {
            Text("🖼 \(self.attachment.filename)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(6)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)
        }
    }
}

// MARK: - Usage bar

/// Bottom status bar showing live token counts and an estimated cost for
/// the active conversation (updates automatically as messages stream in).
private struct UsageBarView: View {

    /// Messages in the active session.
    let messages: [ChatMessage]

    /// Active model id (drives the price lookup).
    let model: String

    /// Dynamic prices fetched from the relay (may be empty).
    let dynamicPrices: [String: ModelPrice]

    // MARK: - Computed state

    /// Live token summary for the conversation.
    private var summary: (input: Int, output: Int) {
        TokenUsage.summarize(self.messages)
    }

    /// Estimated cost — prefers relay dynamic prices, falls back to the table.
    private var estimatedCost: Double? {
        TokenUsage.estimatedCost(
            model: self.model,
            inputTokens: summary.input,
            outputTokens: summary.output,
            dynamicPrices: self.dynamicPrices
        )
    }

    /// Whether the model id is unknown (no dynamic price and no table row).
    private var priceUnknown: Bool {
        !self.model.isEmpty && TokenUsage.prices(
            for: self.model,
            dynamicPrices: self.dynamicPrices
        ) == nil
    }

    /// Whether we're using a relay-provided dynamic price.
    private var usingDynamicPrice: Bool {
        guard let price = self.dynamicPrices[self.model] else { return false }
        return price.isValid
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            Text("Tokens: ↑\(TokenUsage.formatCount(self.summary.input)) ↓\(TokenUsage.formatCount(self.summary.output))")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if self.estimatedCost != nil {
                Text("≈ \(TokenUsage.formatCost(self.estimatedCost!))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if self.priceUnknown {
                Text("(price unknown for this model)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if self.usingDynamicPrice {
                Text("(relay price)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !self.messages.isEmpty {
                Text("\(self.messages.count) msg(s)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Input bar

/// Multi-line input with image attachment support:
/// - NSTextView (Enter sends, Shift+Enter newline, ⌘Enter sends)
/// - 🖼 button opens NSOpenPanel to attach images
/// - thumbnail previews can be removed before sending
private struct InputBarView: View {

    /// Callback invoked with text + attachments to send.
    let onSend: (String, [ImageAttachment]) -> Void

    /// True while a stream is running (disables the send button).
    let isStreaming: Bool

    /// Draft editor state.
    @State private var draft = ""

    /// Images selected but not yet sent.
    @State private var pendingAttachments: [ImageAttachment] = []

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Attachment preview row (below the editor)
            if !self.pendingAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(self.pendingAttachments) { attachment in
                        PendingAttachmentChip(
                            attachment: attachment,
                            onRemove: {
                                self.removeAttachment(attachment)
                            }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .center, spacing: 8) {
                // Image attach button
                Button(action: {
                    self.pickImages()
                }) {
                    Text("🖼")
                        .font(.system(size: 14))
                }
                .buttonStyle(BorderlessButtonStyle())

                MultiLineTextField(text: self.$draft, onEnter: {
                    self.onSubmit()
                })
                .frame(minHeight: 40, maxHeight: 100)

                Button(action: {
                    self.onSubmit()
                }) {
                    Text("Send")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(self.isSendDisabled)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Derived

    private var isSendDisabled: Bool {
        let textEmpty = self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return self.isStreaming || (textEmpty && self.pendingAttachments.isEmpty)
    }

    // MARK: - Actions

    private func onSubmit() {
        let text = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow send when text or images present.
        guard text.isEmpty == false || !self.pendingAttachments.isEmpty else { return }
        guard !self.isStreaming else { return }

        let attachments = self.pendingAttachments
        self.draft = ""
        self.pendingAttachments = []
        self.onSend(text, attachments)
    }

    private func removeAttachment(_ attachment: ImageAttachment) {
        self.pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Opens the native file picker (images only) and converts selections to
    /// base64 `ImageAttachment`s (max ~8MB each to keep the request sane).
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.title = "Attach Image"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            // Heuristic cap: skip files > 10MB (most APIs reject huge payloads).
            if data.count > 10 * 1024 * 1024 {
                continue
            }
            let mime = Self.mimeType(for: url.pathExtension)
            let attachment = ImageAttachment(
                filename: url.lastPathComponent,
                mimeType: mime,
                base64Data: data.base64EncodedString()
            )
            self.pendingAttachments.append(attachment)
        }
    }

    /// Maps a file extension to a MIME type.
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

/// Small thumbnail with an ✕ remove button for pending (unsent) images.
private struct PendingAttachmentChip: View {

    /// Attachment to display.
    let attachment: ImageAttachment

    /// Called when the user taps ✕ to remove this attachment.
    let onRemove: () -> Void

    // MARK: - Body

    @ViewBuilder var body: some View {
        HStack(spacing: 4) {
            // Old ViewBuilder has no `if let` support — use if != nil + force unwrap.
            if self.attachment.decodedData != nil && NSImage(data: self.attachment.decodedData!) != nil {
                Image(nsImage: NSImage(data: self.attachment.decodedData!)!)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .cornerRadius(4)
            } else {
                Text("🖼")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
            }

            Button(action: self.onRemove) {
                Text("✕")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(3)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(6)
    }
}

// MARK: - Multi-line NSTextView wrapper

/// NSViewRepresentable wrapping an NSTextView (Enter sends via callback;
/// Shift+Enter inserts a newline natively).
private struct MultiLineTextField: NSViewRepresentable {

    /// Binding to the draft text.
    @Binding var text: String

    /// Called when the user presses Enter (without Shift).
    let onEnter: () -> Void

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultiLineTextField

        init(_ parent: MultiLineTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
        }

        /// Intercepts Enter (no Shift) → calls send; Shift+Enter inserts newline.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftPressed = NSEvent.modifierFlags.contains(.shift)
                if shiftPressed {
                    // Let the default handler insert a newline.
                    return false
                }
                self.parent.onEnter()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                // Cmd+Enter → also send.
                self.parent.onEnter()
                return true
            }
            return false
        }
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != self.text {
            textView.string = self.text
        }
        // Re-wire the closure (it may capture stale state).
        context.coordinator.parent = self
    }
}

// MARK: - Error banner

/// Dismissible error banner shown when a stream or configuration fails.
struct ErrorBannerView: View {

    /// Message to display.
    let message: String

    /// Called when the user taps the dismiss button.
    let onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("⚠️")
                .font(.system(size: 14))

            Text(self.message)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: self.onDismiss) {
                Text("✕")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        )
    }
}