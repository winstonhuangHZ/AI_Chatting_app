import SwiftUI

/// Left sidebar: list of chat sessions with a "New Chat" button and
/// per-item delete support (modern macOS 14+ List with selection).
struct SidebarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    // MARK: - Body

    var body: some View {
        @Bindable var viewModel = chatViewModel

        List(selection: $viewModel.activeSessionID) {
            ForEach(chatViewModel.sessions) { session in
                SidebarRow(
                    session: session,
                    isSelected: chatViewModel.activeSessionID == session.id
                )
                .tag(session.id)
                .contextMenu {
                    Button("Delete Chat", role: .destructive) {
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
                Label("New Chat", systemImage: "square.and.pencil")
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
                    Text("\(chatViewModel.sessions.count) chat(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        for session in chatViewModel.sessions {
                            chatViewModel.deleteSession(session)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .help("Delete all chats")
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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.body)
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
                    Text("\(session.messages.count) msgs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}