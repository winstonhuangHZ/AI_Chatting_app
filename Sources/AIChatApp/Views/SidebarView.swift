import SwiftUI
import AppKit

/// Left sidebar: list of chat sessions with a "New Chat" button and
/// delete-all support (Swift 5.2 / macOS 10.15-compatible).
struct SidebarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // New Chat button pinned at the top
            Button(action: {
                self.chatViewModel.createNewChat()
            }) {
                Text("＋ New Chat")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BorderedButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if self.chatViewModel.sessions.isEmpty {
                self.emptyState
            } else {
                self.sessionList
            }

            Divider()

            // Footer: count + delete all
            if !self.chatViewModel.sessions.isEmpty {
                HStack {
                    Text("\(self.chatViewModel.sessions.count) chat(s)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        for session in self.chatViewModel.sessions {
                            self.chatViewModel.deleteSession(session)
                        }
                    }) {
                        Text("🗑")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 180)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Session list

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(self.chatViewModel.sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: self.chatViewModel.activeSessionID == session.id
                    )
                    .onTapGesture {
                        self.chatViewModel.selectSession(session)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("💬")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No chats yet")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text("Click “New Chat” to start.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Date formatting

/// 10.15-safe relative time string (Text(date, style: .relative) is 11+).
private func relativeTimeString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

// MARK: - Row

/// A single chat session row in the sidebar.
private struct SessionRow: View {

    /// Session to display.
    let session: ChatSession

    /// Whether this row is currently selected.
    let isSelected: Bool

    // MARK: - Body

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.session.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(self.isSelected ? Color.accentColor : Color.primary)

                HStack(spacing: 4) {
                    Text(relativeTimeString(self.session.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if !self.session.messages.isEmpty {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("\(self.session.messages.count) msgs")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(self.isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}