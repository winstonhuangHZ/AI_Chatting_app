import SwiftUI
import UniformTypeIdentifiers

/// 数据备份/恢复分区：一键导出全部用户数据（聊天历史/配置/画像/外观/语言）为 zip，
/// 一键导入 zip 恢复到当前环境。
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
                    exportBackup()
                } label: {
                    Label(L("backup.export"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button {
                    importBackup()
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
    }

    // MARK: - Actions

    private func exportBackup() {
        isBusy = true
        defer { isBusy = false }

        do {
            let url = try DataTransferService.exportToFile(
                sessions: sessionStore.sessions,
                profiles: configStore.configs,
                preferences: userProfileStore.preferences,
                appearance: appearance,
                language: localization.current.rawValue
            )
            statusMessage = "\(L("backup.exported")) — \(url.lastPathComponent)"
            isError = false
        } catch BackupError.cancelled {
            // 用户取消，不显示错误。
        } catch {
            statusMessage = L("backup.export.failed") + " — \(error.localizedDescription)"
            isError = true
        }
    }

    private func importBackup() {
        isBusy = true
        defer { isBusy = false }

        do {
            let bundle = try DataTransferService.importFromFile()

            // 应用到各 store（SessionStore/ConfigStore/UserProfileStore/AppearanceStore 均有 replaceAll）。
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

            statusMessage = "\(L("backup.imported")) — \(bundle.chatSessions.count) chats, \(bundle.apiProfiles.count) profiles, \(bundle.userPreferences.count) prefs"
            isError = false
        } catch BackupError.cancelled {
            // 用户取消。
        } catch {
            statusMessage = L("backup.import.failed") + " — \(error.localizedDescription)"
            isError = true
        }
    }
}