import SwiftUI

/// Left sidebar: list of chat sessions with a "New Chat" button and
/// per-item delete support (10.15-compatible List).
struct SidebarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // New Chat button pinned at the top
            Button(action: {
                chatViewModel.createNewChat()
            }) {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if chatViewModel.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No chats yet")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text("Click “New Chat” to start.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(
                    chatViewModel.sessions,
                    selection: Binding(
                        get: { chatViewModel.selectedSessionID },
                        set: { chatViewModel.selectSessionID($0) }
                    )
                ) { session in
                    SidebarRow(
                        session: session,
                        isSelected: chatViewModel.selectedSessionID == session.id
                    )
                    .tag(session.id)
                    .onTapGesture {
                        chatViewModel.selectSession(session)
                    }
                }
            }

            Divider()

            // Footer: count + delete all
            if !chatViewModel.sessions.isEmpty {
                HStack {
                    Text("\(chatViewModel.sessions.count) chat(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        for session in chatViewModel.sessions {
                            chatViewModel.deleteSession(session)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Delete all chats")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 180)
        .background(Color(NSColor.windowBackgroundColor))
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
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(isSelected ? Color.accentColor : Color.primary)

                HStack(spacing: 4) {
                    Text(session.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if !session.messages.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(session.messages.count) msgs")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}