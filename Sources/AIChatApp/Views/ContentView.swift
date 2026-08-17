import SwiftUI

/// Root container: a modern `NavigationSplitView` (macOS 14+) with the
/// session sidebar and the chat detail pane.
struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

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