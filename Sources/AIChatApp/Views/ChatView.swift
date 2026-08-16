import SwiftUI
import AppKit

/// Main chat pane: top configuration bar, scrollable message list,
/// streaming indicator, and multi-line input bar.
///
/// Uses only macOS 10.15-compatible SwiftUI API.
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

            if chatViewModel.activeSession != nil {
                MessageList(
                    session: chatViewModel.activeSession!,
                    streamingMessageID: chatViewModel.streamingAssistantID,
                    lastMessageID: $lastMessageID
                )
            } else {
                emptyStateView
            }

            Divider()

            InputBarView(
                onSend: handleSend,
                isStreaming: chatViewModel.isStreaming
            )
        }
        .background(Color(NSColor.textBackgroundColor))
        .onReceive(chatViewModel.$sessions) { sessions in
            // Track the newest message id for auto-scroll.
            if let activeID = chatViewModel.activeSessionID,
               let session = sessions.first(where: { $0.id == activeID }) {
                lastMessageID = session.messages.last?.id
            }
        }
        .overlay(alignment: .top) {
            if let error = chatViewModel.errorMessage {
                ErrorBanner(message: error) {
                    chatViewModel.clearError()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .id(chatViewModel.errorDismissToken)
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Chat Selected")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Choose a chat from the sidebar or create a new one.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func handleSend(_ text: String) {
        chatViewModel.sendMessage(
            text,
            config: configStore.activeConfig,
            model: configStore.activeConfig?.selectedModel ?? ""
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
            Picker("Profile", selection: $configStore.activeConfigID) {
                ForEach(configStore.configs) { config in
                    Text(config.displayName)
                        .tag(Optional(config.id))
                }
                if configStore.configs.isEmpty {
                    Text("No profile — add in Settings (⌘,)")
                        .tag(Optional<UUID>.none)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .frame(minWidth: 160)
            .help("Active API relay profile")

            // Model picker (populated from the active profile)
            if let activeConfig = configStore.activeConfig {
                Picker("Model", selection: modelPickerBinding(for: activeConfig)) {
                    if activeConfig.availableModels.isEmpty {
                        Text("No models — fetch in Settings")
                            .tag("")
                    }
                    ForEach(activeConfig.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(minWidth: 200)
                .help("Model used for chat")
            }

            Spacer()

            // Generation controls
            if chatViewModel.isStreaming {
                ProgressView()
                    .controlSize(.small)
                Button(action: {
                    chatViewModel.cancelStreaming()
                }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(BorderedButtonStyle())
                .foregroundColor(.red)
            } else {
                Button(action: {
                    chatViewModel.createNewChat()
                }) {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(BorderedButtonStyle())
                .help("Start a new chat (⌘N)")
            }

            // Settings accessor
            Button(action: {
                // Send a notification; AppDelegate listens and shows settings.
                NotificationCenter.default.post(
                    name: .showSettingsNotification,
                    object: nil
                )
            }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(BorderedButtonStyle())
            .help("Open API profile settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
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

// MARK: - Notification

extension Notification.Name {
    /// Posted when the user clicks the gear icon; AppDelegate opens Settings.
    static let showSettingsNotification = Notification.Name("AIChatShowSettings")
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
                VStack(spacing: 14) {
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
            .onChange(of: lastMessageID) { newID in
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

/// Renders a single chat message as a bubble with role-appropriate styling.
private struct MessageBubble: View {

    /// Message to display.
    let message: ChatMessage

    /// `true` while this assistant message is being streamed.
    let isStreaming: Bool

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatar
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(roleLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(contentDisplay)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .cornerRadius(10)
                    .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)

                if isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating…")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }

            if message.role == .user {
                avatar
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    // MARK: - Derived content

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.15)
        case .assistant:
            return Color(NSColor.controlBackgroundColor)
        case .system:
            return Color(NSColor.selectedControlColor).opacity(0.4)
        }
    }

    private var contentDisplay: String {
        message.content.isEmpty && isStreaming
            ? "…"
            : message.content
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
            .font(.system(size: 16))
            .foregroundColor(message.role == .user ? Color.accentColor : .purple)
            .frame(width: 24, height: 24)
    }
}

// MARK: - Error banner

/// Dismissible error banner shown when a stream or configuration fails.
private struct ErrorBanner: View {

    /// Message to display.
    let message: String

    /// Called when the user taps the dismiss button.
    let onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
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

// MARK: - Input bar

/// Multi-line input with a Send button (Enter-to-send handled by button focus,
/// Shift+Enter produces a newline natively in NSTextView-backed TextEditor).
private struct InputBarView: View {

    /// Callback invoked with text to send.
    let onSend: (String) -> Void

    /// True while a stream is running (disables the send button).
    let isStreaming: Bool

    /// Draft editor state.
    @State private var draft = ""

    // MARK: - Body

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 40, maxHeight: 120)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .padding(.vertical, 6)

            Button(action: {
                onSubmit()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isSendDisabled ? Color.gray : Color.accentColor)
            }
            .buttonStyle(BorderlessButtonStyle())
            .disabled(isSendDisabled)
            .help("Send")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Derived

    private var isSendDisabled: Bool {
        isStreaming || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func onSubmit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        onSend(text)
    }
}