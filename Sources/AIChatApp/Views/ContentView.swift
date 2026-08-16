import SwiftUI

/// Root container: a two-pane split layout (10.15-compatible HSplitView)
/// with the session sidebar and the chat detail pane.
struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    // MARK: - Body

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            ChatView()
                .frame(minWidth: 420)
        }
    }
}