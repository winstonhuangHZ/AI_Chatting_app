import SwiftUI

/// Root container: a modern `NavigationSplitView` (macOS 14+) with the
/// session sidebar and the chat detail pane.
struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    /// 全局外观（字体预设 / 字号）——观察变化以触发即时刷新。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ChatView()
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(chatViewModel.activeSession?.title ?? L("app.name"))
    }
}