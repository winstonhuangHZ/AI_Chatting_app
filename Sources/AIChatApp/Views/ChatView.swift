import SwiftUI
import AppKit

/// Main chat pane: top configuration bar, scrollable message list,
/// streaming indicator, and multi-line input bar.
///
/// Uses only macOS 10.15-compatible SwiftUI API — no SF Symbols
/// (`Image(systemName:)`), no MenuPickerStyle, explicit `self.` in closures.
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

            InputBarView(
                onSend: handleSend,
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

    // MARK: - Actions

    private func handleSend(_ text: String) {
        self.chatViewModel.sendMessage(
            text,
            config: self.configStore.activeConfig,
            model: self.configStore.activeConfig?.selectedModel ?? ""
        )
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
            // Computed property keeps `if` + locals out of the ViewBuilder.
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

    /// Model picker bound to the active profile's selection.
    private var modelPicker: some View {
        let config = self.configStore.activeConfig!
        return Picker("Model", selection: self.modelPickerBinding(for: config)) {
            if config.availableModels.isEmpty {
                Text("No models — fetch in Settings")
                    .tag("")
            }
            ForEach(config.availableModels, id: \.self) { model in
                Text(model).tag(model)
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

/// Scrollable list of messages (ScrollViewReader is macOS 11+; we rely on
/// the list re-rendering each streaming delta, which keeps the view pinned).
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

/// Renders a single chat message as a bubble with role-appropriate styling.
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

                Text(self.contentDisplay)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(self.bubbleBackground)
                    .cornerRadius(10)
                    .frame(maxWidth: 620, alignment: self.message.role == .user ? .trailing : .leading)

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

// MARK: - Input bar

/// Multi-line input using an AppKit NSTextView wrapper (TextEditor is 11+).
private struct InputBarView: View {

    /// Callback invoked with text to send.
    let onSend: (String) -> Void

    /// True while a stream is running (disables the send button).
    let isStreaming: Bool

    /// Draft editor state.
    @State private var draft = ""

    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
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
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Derived

    private var isSendDisabled: Bool {
        self.isStreaming || self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func onSubmit() {
        let text = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !self.isStreaming else { return }
        self.draft = ""
        self.onSend(text)
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
/// Rendered via `.overlay` in the parent (overlay(alignment:) is 12+).
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