import SwiftUI

/// Left sidebar: list of chat sessions with a "New Chat" button and
/// per-item delete support (modern macOS 14+ List with selection).
struct SidebarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    /// 全局外观（字体预设 / 字号）——观察变化以触发即时刷新。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        // Custom selection binding: writing back goes through
        // `chatViewModel.selectSession(id:)`, which ALSO updates
        // `sessionStore.activeSessionID` so the message-history builder in
        // `sendMessage` reads the correct session after app relaunch.
        List(selection: Binding(
            get: { chatViewModel.activeSessionID },
            set: { chatViewModel.selectSession(id: $0) }
        )) {
            ForEach(chatViewModel.sessions) { session in
                SidebarRow(
                    session: session,
                    isSelected: chatViewModel.activeSessionID == session.id
                )
                .tag(session.id)
                .contextMenu {
                    Button(L("delete.chat"), role: .destructive) {
                        chatViewModel.deleteSession(session)
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    if chatViewModel.sessions.indices.contains(index) {
                        chatViewModel.deleteSession(chatViewModel.sessions[index])
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Button(action: {
                chatViewModel.createNewChat()
            }) {
                Label(L("new.chat"), systemImage: "square.and.pencil")
                    .font(appearance.fontPreset.font(size: appearance.pointSize))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if !chatViewModel.sessions.isEmpty {
                HStack {
                    Text(L("chat.count", chatViewModel.sessions.count))
                        .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        for session in chatViewModel.sessions {
                            chatViewModel.deleteSession(session)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .help(L("delete.all.chats"))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Row

/// A single chat session row in the sidebar.
private struct SidebarRow: View {

    /// Session to display.
    let session: ChatSession

    /// Whether this row is currently selected.
    let isSelected: Bool

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

            HStack(spacing: 4) {
                Text(session.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !session.messages.isEmpty {
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(L("msgs.count", session.messages.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}