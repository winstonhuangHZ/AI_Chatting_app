import SwiftUI
import UniformTypeIdentifiers

/// 数据备份/恢复分区：一键导出/导入全部用户数据。
/// 点「导出/导入」后先选择格式（ZIP 或 SQLite），再弹保存/打开面板。
struct BackupRestoreView: View {

    // MARK: - Environment

    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var userProfileStore: UserProfileStore
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - State

    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var pendingAction: BackupAction?

    /// 导出 / 导入操作的格式选择弹窗。
    enum BackupAction: Identifiable {
        case export
        case importBackup

        var id: String {
            switch self {
            case .export: return "export"
            case .importBackup: return "import"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("backup.title"), systemImage: "externaldrive.badge.checkmark")
                .font(.headline)

            Text(L("backup.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    pendingAction = .export
                } label: {
                    Label(L("backup.export"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button {
                    pendingAction = .importBackup
                } label: {
                    Label(L("backup.import"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }

            if let status = statusMessage {
                Label(status, systemImage: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : .secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 格式选择弹窗：点「导出/导入」后先选 ZIP 或 SQLite。
        .confirmationDialog(
            pendingAction == .export ? L("backup.export.choose_format") : L("backup.import.choose_format"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("\(BackupFormat.zip.displayName) (.zip)") {
                let action = pendingAction
                pendingAction = nil
                handle(action: action, format: .zip)
            }
            Button("\(BackupFormat.sqlite.displayName) (.sqlite)") {
                let action = pendingAction
                pendingAction = nil
                handle(action: action, format: .sqlite)
            }
            Button(L("cancel"), role: .cancel) {
                pendingAction = nil
            }
        }
    }

    // MARK: - Actions

    private func handle(action: BackupAction?, format: BackupFormat) {
        switch action {
        case .export:
            exportBackup(format: format)
        case .importBackup, .none:
            importBackup(format: format)
        }
    }

    private func exportBackup(format: BackupFormat) {
        isBusy = true

        guard let url = DataTransferService.presentExportPanel(format: format) else {
            isBusy = false
            return
        }

        // 快照在主线程收集；重活由 writeExport 放到后台任务。
        let sessions = sessionStore.sessions
        let profiles = configStore.configs
        let preferences = userProfileStore.preferences
        let backupAppearance = BackupAppearance(
            fontPreset: appearance.fontPreset.rawValue,
            fontSizeLevel: appearance.fontSizeLevel.rawValue,
            theme: appearance.theme.rawValue
        )
        let language = localization.current.rawValue
        let displayName = userProfileStore.displayName
        let avatarData = userProfileStore.avatarData

        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await DataTransferService.writeExport(
                    format: format,
                    to: url,
                    sessions: sessions,
                    profiles: profiles,
                    preferences: preferences,
                    appearance: backupAppearance,
                    language: language,
                    displayName: displayName,
                    avatarData: avatarData
                )
                statusMessage = "\(L("backup.exported")) — \(url.lastPathComponent)"
                isError = false
            } catch {
                statusMessage = L("backup.export.failed") + " — \(error.localizedDescription)"
                isError = true
            }
        }
    }

    private func importBackup(format: BackupFormat) {
        // format 仅用于打开面板时提示（导入时自动按扩展名识别），
        // 这里显式引用避免未使用警告；实际解析由 importFromFile 完成。
        _ = format

        guard let url = DataTransferService.presentImportPanel() else {
            return
        }
        isBusy = true

        Task { @MainActor in
            defer { isBusy = false }
            do {
                let bundle = try await DataTransferService.importBackup(from: url)

                // 应用到各 store（均有 replaceAll）。
                sessionStore.replaceAll(with: bundle.chatSessions)
                configStore.replaceAll(with: bundle.apiProfiles)
                userProfileStore.replaceAll(with: bundle.userPreferences)

                if let backupAppearance = bundle.appearance {
                    appearance.apply(from: backupAppearance)
                }

                if let langStr = bundle.appLanguage,
                   let lang = AppLanguage(rawValue: langStr) {
                    localization.current = lang
                }

                // Account display name / avatar were not part of older backups;
                // only apply them when the restored backup actually contains them.
                if let displayName = bundle.displayName {
                    userProfileStore.displayName = displayName
                }
                if let avatarData = bundle.avatarData {
                    userProfileStore.avatarData = avatarData
                }

                statusMessage = "\(L("backup.imported")) — \(bundle.chatSessions.count) chats, \(bundle.apiProfiles.count) profiles, \(bundle.userPreferences.count) prefs"
                isError = false
            } catch {
                statusMessage = L("backup.import.failed") + " — \(error.localizedDescription)"
                isError = true
            }
        }
    }
}
