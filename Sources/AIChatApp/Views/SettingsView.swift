import SwiftUI

/// Settings window (macOS 14+): manages API relay profiles.
struct SettingsView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel

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
        .frame(minWidth: 520, minHeight: 440)
        .alert(
            appSettingViewModel.statusIsError ? "Operation Failed" : "Success",
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

    let onAdd: () -> Void
    let onEdit: (APIServerConfig) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("API Relay Profiles").font(.title2.bold())
                Spacer()
                Button(action: onAdd) { Label("Add Profile", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            if configStore.configs.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "network.slash")
                } description: {
                    Text("Add an OpenAI-compatible relay server to start chatting.")
                } actions: {
                    Button("Add Profile", action: onAdd)
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
        }
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
                    Text("Active").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(config.baseURL.isEmpty ? "No base URL set" : config.baseURL)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(config.apiKey.isEmpty ? "No API key set" : "API key: ••••••••")
                    .font(.caption).foregroundStyle(.secondary)
                Text(config.selectedModel.isEmpty
                     ? "No model selected"
                     : "Model: \(config.selectedModel)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(config.availableModels.isEmpty ? "Fetch Models" : "\(config.availableModels.count) models",
                       action: onFetchModels)
                    .buttonStyle(.bordered)
                Button("Test", action: onTest).buttonStyle(.bordered)
                Button("Edit", action: onEdit).buttonStyle(.bordered)
                Spacer()
                Button("Delete", role: .destructive, action: onDelete).buttonStyle(.bordered)
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
            Text(isNew ? "Add Profile" : "Edit Profile").font(.title2.bold())

            Form {
                TextField("Profile Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL)
                SecureField("API Key", text: $draft.apiKey)

                if !isNew {
                    Section("Models") {
                        Picker("Selected Model", selection: $draft.selectedModel) {
                            if draft.availableModels.isEmpty {
                                Text("No models yet").tag("")
                            }
                            ForEach(draft.availableModels, id: \.self) { model in
                                Text(MultimodalSupport.displayName(model)).tag(model)
                            }
                        }
                        .disabled(draft.availableModels.isEmpty)

                        Label("🖼 = multimodal (vision) model",
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
                                Label("Fetch Models", systemImage: "arrow.clockwise")
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
                Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button(action: save) {
                    Text(isNew ? "Add" : "Save")
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