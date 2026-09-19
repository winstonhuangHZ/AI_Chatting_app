import SwiftUI
import AppKit

/// Left sidebar: list of chat sessions with a "New Chat" button and
/// per-item delete support (modern macOS 14+ List with selection).
struct SidebarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    /// 全局外观（字体预设 / 字号）——观察变化以触发即时刷新。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    /// 删除全部会话前的二次确认。
    @State private var confirmDeleteAll = false

    /// 当前正在重命名/换 emoji 的会话。
    @State private var sessionToEdit: ChatSession?

    /// 文件夹新建/重命名弹窗状态。
    @State private var folderEditorTarget: FolderEditorTarget?

    /// 正在查看摘要的会话。
    @State private var summaryTarget: ChatSession?

    /// 搜索框输入（防抖后写入 ViewModel，避免每次按键全量扫历史）。
    @State private var searchText = ""

    // MARK: - Body

    var body: some View {
        Group {
            if isSearching {
                searchResultsList
            } else {
                VStack(spacing: 0) {
                    personalizationSection
                    sessionList
                }
            }
        }
        .background(appearance.sidebarBackground)
        .sheet(item: $sessionToEdit) { session in
            SessionIdentitySheet(session: session)
                .environmentObject(chatViewModel)
                .environmentObject(appearance)
                .environmentObject(localization)
        }
        .sheet(item: $folderEditorTarget) { target in
            FolderEditorSheet(target: target)
                .environmentObject(chatViewModel)
                .environmentObject(appearance)
                .environmentObject(localization)
        }
        .sheet(item: $summaryTarget) { session in
            SessionSummarySheet(session: session)
                .environmentObject(chatViewModel)
                .environmentObject(appearance)
                .environmentObject(localization)
        }
        .confirmationDialog(
            L("delete.all.confirm.title"),
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button(L("delete.all.chats"), role: .destructive) {
                chatViewModel.deleteAllSessions()
            }
            Button(L("cancel"), role: .cancel) {}
        } message: {
            Text(L("delete.all.confirm.message"))
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                searchField
                // 「新建会话」铺满整行；右侧小箭头在按钮内部，点开才是「添加个性化块」。
                Menu {
                    Button {
                        chatViewModel.createNewChat()
                    } label: {
                        Label(L("new.chat"), systemImage: "square.and.pencil")
                    }
                    Button {
                        chatViewModel.createPersonalizationCollection()
                    } label: {
                        Label(L("kb.add"), systemImage: "brain")
                    }
                    Divider()
                    Button {
                        folderEditorTarget = .create
                    } label: {
                        Label(L("folder.new"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Label(L("new.chat"), systemImage: "square.and.pencil")
                            .font(appearance.fontPreset.font(size: appearance.pointSize))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(appearance.fontPreset.font(size: appearance.pointSize - 2))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(appearance.prominentButtonColor)
                    )
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.large)
                .disabled(isSearching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if !chatViewModel.sessions.isEmpty && !isSearching {
                HStack {
                    Text(L("chat.count", chatViewModel.sessions.count))
                        .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        confirmDeleteAll = true
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

    // MARK: - Search

    /// `true` when the user is actively searching (query non-empty).
    private var isSearching: Bool {
        !chatViewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Search field: magnifier + query + clear button.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(L("search.placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
                .task(id: searchText) {
                    // Debounce: full-text search over all sessions runs on the
                    // main actor, so don't recompute on every keystroke.
                    let value = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.isEmpty {
                        if !chatViewModel.searchQuery.isEmpty {
                            chatViewModel.updateSearchQuery("")
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    chatViewModel.updateSearchQuery(searchText)
                }
            if !chatViewModel.searchQuery.isEmpty {
                Button {
                    searchText = ""
                    chatViewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("search.clear"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Saved personalization blocks: user-curated named facts the model can
    /// fetch via `fetch_personalization_block`. Collapsible; only shown when at
    /// least one block exists.
    private var personalizationSection: some View {
        Group {
            if !chatViewModel.personalizationBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("kb.title", chatViewModel.personalizationBlocks.count))
                        .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    ForEach(chatViewModel.personalizationBlocks) { block in
                        PersonalizationBlockRow(block: block) {
                            chatViewModel.deletePersonalizationBlock(block)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.035))

                Divider()
            }
        }
    }

    /// Full-text search result list (replaces the session list while searching).
    private var searchResultsList: some View {
        let results = chatViewModel.searchResults
        return Group {
            if results.isEmpty {
                ContentUnavailableView(
                    L("search.no.results"),
                    systemImage: "magnifyingglass",
                    description: Text(L("search.no.results.description"))
                )
            } else {
                List(results) { result in
                    SearchResultRow(result: result) {
                        chatViewModel.selectSearchResult(result)
                    }
                    .tag(result.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Normal session list. Uses scroll + manual selection highlight instead of
    /// `List(selection:)`: macOS 14+ renders the List selection highlight as a
    /// fixed system-blue overlay on interaction that cannot be themed, so the
    /// row draws its own selection tint (clay on Claude, system accent otherwise).
    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if chatViewModel.folders.isEmpty {
                    ForEach(chatViewModel.sidebarSessions) { session in
                        sessionRow(session)
                    }
                } else {
                    ForEach(chatViewModel.folders) { folder in
                        DisclosureGroup {
                            ForEach(chatViewModel.sessions(in: folder.id)) { session in
                                sessionRow(session)
                            }
                        } label: {
                            folderHeader(folder)
                        }
                    }

                    let uncategorized = chatViewModel.sessions(in: nil)
                    if !uncategorized.isEmpty {
                        DisclosureGroup {
                            ForEach(uncategorized) { session in
                                sessionRow(session)
                            }
                        } label: {
                            Label(L("folder.uncategorized"), systemImage: "tray")
                                .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func folderHeader(_ folder: ChatFolder) -> some View {
        Label(folder.name, systemImage: "folder")
            .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
            .contextMenu {
                let shared = folder.sharedContextEnabled == true
                Button {
                    chatViewModel.setFolderSharedContext(folder, enabled: !shared)
                } label: {
                    Label(
                        L(shared ? "folder.share.disable" : "folder.share.enable"),
                        systemImage: shared ? "eye.slash" : "eye"
                    )
                }

                Divider()

                Button {
                    folderEditorTarget = .rename(folder)
                } label: {
                    Label(L("folder.rename"), systemImage: "pencil")
                }
                Button(L("delete"), role: .destructive) {
                    chatViewModel.deleteFolder(folder)
                }
            }
    }

    @ViewBuilder
    private func sessionRow(_ session: ChatSession) -> some View {
        SidebarRow(
            session: session,
            isSelected: chatViewModel.activeSessionID == session.id,
            onSelect: { chatViewModel.selectSession(id: session.id) }
        )
        .contextMenu {
            Button {
                chatViewModel.togglePinSession(session)
            } label: {
                Label(
                    L(session.isPinned ? "session.unpin" : "session.pin"),
                    systemImage: session.isPinned ? "pin.slash" : "pin"
                )
            }

            Button {
                sessionToEdit = session
            } label: {
                Label(L("session.rename"), systemImage: "pencil")
            }

            Divider()

            Button {
                chatViewModel.generateSessionSummary(for: session)
            } label: {
                Label(L("summary.generate"), systemImage: "text.badge.plus")
            }
            .disabled(session.messageCount == 0
                      || chatViewModel.summaryGenerating.contains(session.id))

            if chatViewModel.summary(for: session) != nil {
                Button {
                    summaryTarget = session
                } label: {
                    Label(L("summary.view"), systemImage: "doc.text.magnifyingglass")
                }
            }

            if !chatViewModel.folders.isEmpty {
                Menu {
                    Button(L("folder.uncategorized")) {
                        chatViewModel.moveSession(session, to: nil)
                    }
                    Divider()
                    ForEach(chatViewModel.folders) { folder in
                        Button(folder.name) {
                            chatViewModel.moveSession(session, to: folder.id)
                        }
                    }
                } label: {
                    Label(L("folder.move"), systemImage: "folder")
                }
            }

            Divider()

            Button {
                exportPDF(session)
            } label: {
                Label(L("export.pdf"), systemImage: "arrow.down.doc")
            }
            .disabled(session.messageCount == 0)

            Divider()

            Button(L("delete.chat"), role: .destructive) {
                chatViewModel.deleteSession(session)
            }
        }
    }

    // MARK: - PDF export

    /// Exports one session to PDF, surfacing failures in the chat error banner.
    private func exportPDF(_ session: ChatSession) {
        chatViewModel.ensureMessagesLoaded(for: session)
        // 导出会在保存面板之后先把回答里的网络图片下载进缓存，再逐块渲染 PDF，
        // 所以整体是异步的（面板本身仍在主线程弹出）。
        Task {
            do {
                if let url = try await PDFExportService.export(
                    session: session,
                    appearance: appearance,
                    localization: localization
                ) {
                    // Reveal the file so the user gets immediate confirmation.
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                chatViewModel.errorMessage = error.localizedDescription
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

    /// Selects this session.
    let onSelect: () -> Void

    /// Hover state for a subtle non-selected rollover background.
    @State private var isHovering = false

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if session.isPersonalizationCollection {
                        Image(systemName: "brain")
                            .font(.caption2)
                            .foregroundStyle(appearance.accentColor)
                    }
                    if let emoji = session.emoji, !emoji.isEmpty {
                        Text(emoji)
                            .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                    }
                    Text(session.title)
                        .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? appearance.accentColor : Color.primary)
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    Text(session.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if session.messageCount > 0 {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(L("msgs.count", session.messageCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    /// Row fill: theme selection tint when selected, soft gray rollover
    /// otherwise. Fully self-drawn — no system List highlight involved.
    private var rowBackgroundColor: Color {
        if isSelected {
            return appearance.sidebarSelectionColor
        }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }
}

/// One saved personalization block in the sidebar: name (click to preview the
/// content) + delete. The model reads these by name via `fetch_personalization_block`.
private struct PersonalizationBlockRow: View {

    let block: PersonalizationBlock
    let onDelete: () -> Void

    @EnvironmentObject private var appearance: AppearanceStore
    @State private var isHovering = false
    @State private var showContent = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showContent = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(appearance.accentColor)
                    Text(block.name)
                        .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showContent) {
                PersonalizationBlockContent(block: block)
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
    }
}

/// Popover showing a personalization block's stored content (selectable text).
private struct PersonalizationBlockContent: View {

    let block: PersonalizationBlock

    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(block.name)
                .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                .bold()
            ScrollView {
                Text(block.content)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
    }
}

// MARK: - Session identity editor (title + emoji)

private enum FolderEditorTarget: Identifiable {
    case create
    case rename(ChatFolder)

    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let folder): return folder.id.uuidString
        }
    }
}

/// Small sheet for creating or renaming a sidebar folder.
private struct FolderEditorSheet: View {
    let target: FolderEditorTarget

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(target: FolderEditorTarget) {
        self.target = target
        switch target {
        case .create:
            _name = State(initialValue: "")
        case .rename(let folder):
            _name = State(initialValue: folder.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.isNew ? L("folder.new") : L("folder.rename"))
                .font(.headline)
            TextField(L("folder.name"), text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L("cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                Button(L("save")) {
                    switch target {
                    case .create:
                        chatViewModel.createFolder(named: name)
                    case .rename(let folder):
                        chatViewModel.renameFolder(folder, to: name)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(appearance.prominentButtonColor)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

private extension FolderEditorTarget {
    var isNew: Bool {
        if case .create = self { return true }
        return false
    }
}

/// Sheet that shows a session's generated summary.
private struct SessionSummarySheet: View {
    let session: ChatSession

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(L("summary.title"), systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                if chatViewModel.summaryGenerating.contains(session.id) {
                    ProgressView().controlSize(.small)
                }
            }

            if let summary = chatViewModel.summary(for: session) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if summary.status == .stale {
                        Label(L("summary.stale"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(summary.updatedAt.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ScrollView {
                    Text(summary.summary)
                        .font(appearance.fontPreset.font(size: appearance.pointSize))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 340)

                HStack {
                    Button(L("summary.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.summary, forType: .string)
                    }
                    .buttonStyle(.bordered)

                    Button(L("summary.refresh")) {
                        chatViewModel.generateSessionSummary(for: session)
                    }
                    .buttonStyle(.bordered)
                    .disabled(chatViewModel.summaryGenerating.contains(session.id))

                    Spacer()
                    Button(L("close")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(appearance.prominentButtonColor)
                }
            } else {
                Text(L("summary.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(L("summary.generate")) {
                        chatViewModel.generateSessionSummary(for: session)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appearance.prominentButtonColor)
                    Button(L("close")) { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

/// Sheet used from the sidebar context menu to manually name a conversation
/// and choose its emoji.
private struct SessionIdentitySheet: View {
    let session: ChatSession

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var emoji: String

    init(session: ChatSession) {
        self.session = session
        _title = State(initialValue: session.title)
        _emoji = State(initialValue: session.emoji ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("session.rename"))
                .font(.headline)

            TextField(L("session.title"), text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField(L("session.emoji"), text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Text(L("session.emoji.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L("cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                Button(L("save")) {
                    chatViewModel.updateSessionIdentity(
                        title: title,
                        emoji: emoji,
                        for: session
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(appearance.prominentButtonColor)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

// MARK: - Search result row

/// One full-text search hit: session title + snippet + role badge.
private struct SearchResultRow: View {

    let result: MessageSearchResult
    let onSelect: () -> Void

    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.sessionTitle)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                Text(result.snippet)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(result.message.role == .user ? L("you") : L("assistant"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
