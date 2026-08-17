import SwiftUI

/// Settings window (macOS 14+): manages API relay profiles + user profile
/// (learned personalization preferences).
struct SettingsView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var userProfileStore: UserProfileStore

    @State private var editingConfig: APIServerConfig?
    @State private var isAddingNew = false
    @State private var showStatusAlert = false

    var body: some View {
        Group {
            if let config = editingConfig {
                ProfileEditView(
                    config: config,
                    isNew: isAddingNew,
                    onSave: { updated in
                        if isAddingNew {
                            appSettingViewModel.add(updated)
                        } else {
                            appSettingViewModel.update(updated)
                        }
                        editingConfig = nil
                    },
                    onCancel: { editingConfig = nil }
                )
            } else {
                ProfileListView(
                    onAdd: {
                        isAddingNew = true
                        editingConfig = APIServerConfig(name: "New Profile")
                    },
                    onEdit: { editingConfig = $0 }
                )
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .alert(
            appSettingViewModel.statusIsError ? L("operation.failed") : L("success"),
            isPresented: $showStatusAlert
        ) {
            Button("OK", role: .cancel) { appSettingViewModel.clearStatus() }
        } message: {
            Text(appSettingViewModel.statusMessage ?? "")
        }
        .onChange(of: appSettingViewModel.statusMessage) { _, message in
            if message != nil { showStatusAlert = true }
        }
    }
}

// MARK: - Profile list

private struct ProfileListView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var userProfileStore: UserProfileStore

    let onAdd: () -> Void
    let onEdit: (APIServerConfig) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("api.relay.profiles")).font(.title2.bold())
                Spacer()
                Button(action: onAdd) { Label(L("add.profile"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            if configStore.configs.isEmpty {
                ContentUnavailableView {
                    Label(L("no.profiles"), systemImage: "network.slash")
                } description: {
                    Text(L("no.profiles.description"))
                } actions: {
                    Button(L("add.profile"), action: onAdd)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(configStore.configs) { config in
                    ProfileRow(
                        config: config,
                        isActive: configStore.activeConfigID == config.id,
                        isTesting: appSettingViewModel.isTestingConnection
                            && configStore.activeConfigID == config.id,
                        onActivate: { configStore.activeConfigID = config.id },
                        onEdit: { onEdit(config) },
                        onDelete: { appSettingViewModel.delete(config) },
                        onFetchModels: {
                            Task { await appSettingViewModel.fetchModels(for: config.id) }
                        },
                        onTest: {
                            Task { await appSettingViewModel.testConnection(for: config) }
                        }
                    )
                }
            }

            Divider()

            // User Profile section: learned personalization preferences.
            UserProfileSection()
                .environmentObject(userProfileStore)

            Divider()

            // Interface language picker (UN official languages).
            LanguagePickerView()
                .environmentObject(LocalizationManager.shared)
        }
    }
}

// MARK: - User profile section

/// Editable list of learned personalization preferences.
private struct UserProfileSection: View {
    @EnvironmentObject private var userProfileStore: UserProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("user.profile"), systemImage: "person")
                .font(.headline)

            Text(L("user.profile.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if userProfileStore.preferences.isEmpty {
                Text(L("no.preferences.learned"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                List {
                    ForEach($userProfileStore.preferences) { $pref in
                        HStack(spacing: 8) {
                            TextField("category", text: $pref.category)
                                .font(.caption)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)

                            TextField("value", text: $pref.value)
                                .font(.body)
                                .textFieldStyle(.roundedBorder)

                            Spacer()

                            Button(role: .destructive) {
                                userProfileStore.remove(pref)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(height: CGFloat(min(userProfileStore.preferences.count, 6)) * 30 + 14)
            }
        }
        .padding(16)
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let config: APIServerConfig
    let isActive: Bool
    let isTesting: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onFetchModels: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(config.displayName).font(.headline)
                if isActive {
                    Text(L("active")).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(config.baseURL.isEmpty ? L("no.base.url") : config.baseURL)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(config.apiKey.isEmpty ? L("no.api.key") : "API key: ••••••••")
                    .font(.caption).foregroundStyle(.secondary)
                Text(config.selectedModel.isEmpty
                     ? L("no.model.selected")
                     : "Model: \(config.selectedModel)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(config.availableModels.isEmpty
                       ? L("fetch.models")
                       : L("models.count", config.availableModels.count),
                       action: onFetchModels)
                    .buttonStyle(.bordered)
                Button(L("test"), action: onTest).buttonStyle(.bordered)
                Button(L("edit"), action: onEdit).buttonStyle(.bordered)
                Spacer()
                Button(L("delete"), role: .destructive, action: onDelete).buttonStyle(.bordered)
            }
            .font(.callout)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Profile editor

private struct ProfileEditView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel

    @State private var draft: APIServerConfig
    let isNew: Bool
    let onSave: (APIServerConfig) -> Void
    let onCancel: () -> Void

    init(
        config: APIServerConfig,
        isNew: Bool,
        onSave: @escaping (APIServerConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? L("add.profile.title") : L("edit.profile.title")).font(.title2.bold())

            Form {
                TextField(L("profile.name"), text: $draft.name)
                TextField(L("base.url"), text: $draft.baseURL)
                SecureField(L("api.key"), text: $draft.apiKey)

                Section {
                    Toggle(L("streaming.on"), isOn: $draft.streamEnabled)

                    Toggle(L("timestamp.on"), isOn: $draft.includeTimestamp)
                } header: {
                    Text(L("generation"))
                } footer: {
                    Text(L("generation.footer"))
                }

                Section {
                    TextEditor(text: $draft.systemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                    Label(L("system.prompt.hint"),
                          systemImage: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L("system.prompt"))
                } footer: {
                    Text(L("system.prompt.footer"))
                }

                if !isNew {
                    Section(L("models")) {
                        Picker(L("selected.model"), selection: $draft.selectedModel) {
                            if draft.availableModels.isEmpty {
                                Text(L("no.models.yet")).tag("")
                            }
                            ForEach(draft.availableModels, id: \.self) { model in
                                Text(MultimodalSupport.displayName(model)).tag(model)
                            }
                        }
                        .disabled(draft.availableModels.isEmpty)

                        Label(L("multimodal.hint"),
                              systemImage: "photo.on.rectangle")
                            .font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Button {
                                Task {
                                    await appSettingViewModel.fetchModels(for: draft.id)
                                    if let updated = configStore.configs.first(where: { $0.id == draft.id }) {
                                        draft = updated
                                    }
                                }
                            } label: {
                                Label(L("fetch.models.button"), systemImage: "arrow.clockwise")
                            }
                            .disabled(appSettingViewModel.isLoadingModels)

                            if appSettingViewModel.isLoadingModels {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(L("cancel"), role: .cancel, action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button(action: save) {
                    Text(isNew ? L("add") : L("save"))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .onAppear {
            if let existing = configStore.configs.first(where: { $0.id == draft.id }) {
                draft = existing
            }
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(draft)
    }
}