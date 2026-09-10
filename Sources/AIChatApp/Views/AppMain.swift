import SwiftUI
import AppKit

/// Modern SwiftUI app entry point (macOS 14+).
@main
struct AIChatApp: App {

    // MARK: - Shared state

    /// Persists API relay profiles.
    @StateObject private var configStore: ConfigStore

    /// Persists chat sessions.
    @StateObject private var sessionStore: SessionStore

    /// Persists learned user preferences for personalization.
    @StateObject private var userProfileStore: UserProfileStore

    /// Drives the chat UI.
    @StateObject private var chatViewModel: ChatViewModel

    /// Drives the settings UI.
    @StateObject private var appSettingViewModel: AppSettingViewModel

    /// Interface localization.
    @StateObject private var localizationManager = LocalizationManager.shared

    /// Interface appearance (font preset + size).
    @StateObject private var appearanceStore = AppearanceStore()

    // MARK: - Initializers

    init() {
        // 注册用户导入的衬线字体（见 ImportedFontManager；未导入时无操作）。
        ImportedFontManager.shared.activateInstalled()

        // 建立唯一的 store 层级，所有层共享同一实例。
        let configStore = ConfigStore()
        let sessionStore = SessionStore()
        let personalizationStore = PersonalizationStore()

        _configStore = StateObject(wrappedValue: configStore)
        _sessionStore = StateObject(wrappedValue: sessionStore)
        let profileStore = UserProfileStore()
        _userProfileStore = StateObject(wrappedValue: profileStore)
        _chatViewModel = StateObject(
            wrappedValue: ChatViewModel(
                sessionStore: sessionStore,
                configStore: configStore,
                service: OpenAIService(),
                userProfileStore: profileStore,
                personalizationStore: personalizationStore
            )
        )
        _appSettingViewModel = StateObject(
            wrappedValue: AppSettingViewModel(configStore: configStore)
        )
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(configStore)
                .environmentObject(sessionStore)
                .environmentObject(chatViewModel)
                .environmentObject(appSettingViewModel)
                .environmentObject(userProfileStore)
                .environmentObject(localizationManager)
                .environmentObject(appearanceStore)
                // Claude theme is a light cream palette — force light appearance.
                .preferredColorScheme(appearanceStore.isClaudeTheme ? .light : nil)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        // 标准 macOS 设置窗口。
        Settings {
            SettingsView()
                .environmentObject(configStore)
                .environmentObject(sessionStore)
                .environmentObject(chatViewModel)
                .environmentObject(appSettingViewModel)
                .environmentObject(userProfileStore)
                .environmentObject(localizationManager)
                .environmentObject(appearanceStore)
        }
        // 默认开一个足够大的设置窗口，且允许用户自由缩放，
        // 保证底层（外观/备份/语言）分区不会被窗口高度截断。
        .defaultSize(width: 740, height: 680)

        MenuBarExtra("AI Chat", systemImage: "bubble.left.and.bubble.right") {
            QuickAskMenuView()
                .environmentObject(configStore)
                .environmentObject(sessionStore)
                .environmentObject(chatViewModel)
                .environmentObject(userProfileStore)
                .environmentObject(appearanceStore)
                .environmentObject(localizationManager)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Small menu-bar popover for a one-shot question. Sending creates a new chat
/// so it never disturbs the conversation currently open in the main window.
private struct QuickAskMenuView: View {
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.openWindow) private var openWindow

    @State private var text = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Chat")
                .font(.headline)

            TextEditor(text: $text)
                .font(appearance.fontPreset.font(size: appearance.pointSize))
                .frame(width: 320, height: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                }

            HStack {
                Button(L("quick.send")) {
                    send()
                }
                .buttonStyle(.borderedProminent)
                .tint(appearance.prominentButtonColor)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || configStore.activeConfig == nil)

                Button(L("quick.open")) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let config = configStore.activeConfig else { return }
        chatViewModel.createNewChat()
        chatViewModel.sendMessage(
            trimmed,
            config: config,
            model: config.selectedModel
        )
        text = ""
        status = L("quick.sent")
    }
}
