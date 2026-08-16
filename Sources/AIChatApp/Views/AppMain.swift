import SwiftUI

/// Modern SwiftUI app entry point (macOS 14+).
@main
struct AIChatApp: App {

    // MARK: - Shared state

    /// Persists API relay profiles.
    @StateObject private var configStore = ConfigStore()

    /// Persists chat sessions.
    @StateObject private var sessionStore = SessionStore()

    /// Drives the chat UI.
    @StateObject private var chatViewModel: ChatViewModel

    /// Drives the settings UI.
    @StateObject private var appSettingViewModel: AppSettingViewModel

    // MARK: - Initializers

    init() {
        // 建立唯一的 store 层级，所有层共享同一实例。
        let configStore = ConfigStore()
        let sessionStore = SessionStore()

        _configStore = StateObject(wrappedValue: configStore)
        _sessionStore = StateObject(wrappedValue: sessionStore)
        _chatViewModel = StateObject(
            wrappedValue: ChatViewModel(
                sessionStore: sessionStore,
                configStore: configStore,
                service: OpenAIService()
            )
        )
        _appSettingViewModel = StateObject(
            wrappedValue: AppSettingViewModel(configStore: configStore)
        )
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configStore)
                .environmentObject(sessionStore)
                .environmentObject(chatViewModel)
                .environmentObject(appSettingViewModel)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        // 标准 macOS 设置窗口。
        Settings {
            SettingsView()
                .environmentObject(configStore)
                .environmentObject(appSettingViewModel)
        }
    }
}