import SwiftUI
import AppKit

/// Settings window: manages API relay profiles (add / edit / delete),
/// connection testing, and model list fetching.
///
/// Uses only macOS 10.15-compatible SwiftUI API.
struct SettingsView: View {

    // MARK: - Environment

    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel

    // MARK: - Local state

    /// Draft profile being edited; nil means "show the list".
    @State private var editingConfig: APIServerConfig?

    /// True when a new profile form is presented.
    @State private var isAddingNew = false

    /// Controls whether the status alert is displayed.
    @State private var showStatusAlert = false

    // MARK: - Body

    var body: some View {
        Group {
            if let editingConfig {
                ProfileEditView(
                    config: editingConfig,
                    isNew: isAddingNew,
                    onSave: { updated in
                        if isAddingNew {
                            appSettingViewModel.add(updated)
                        } else {
                            appSettingViewModel.update(updated)
                        }
                        self.editingConfig = nil
                    },
                    onCancel: {
                        self.editingConfig = nil
                    }
                )
            } else {
                ProfileListView(
                    onAdd: {
                        isAddingNew = true
                        editingConfig = APIServerConfig(name: "New Profile")
                    },
                    onEdit: { config in
                        isAddingNew = false
                        editingConfig = config
                    }
                )
            }
        }
        .frame(width: 520, height: 440)
        .alert(isPresented: $showStatusAlert) {
            Alert(
                title: Text(appSettingViewModel.statusIsError ? "Operation Failed" : "Success"),
                message: Text(appSettingViewModel.statusMessage ?? ""),
                dismissButton: .default(Text("OK")) {
                    appSettingViewModel.clearStatus()
                }
            )
        }
        .onReceive(appSettingViewModel.$statusMessage) { message in
            if message != nil {
                showStatusAlert = true
            }
        }
    }
}

// MARK: - Profile list

/// Renders the list of saved profiles with edit/delete actions.
private struct ProfileListView: View {

    // MARK: - Environment

    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel

    /// Called when the user taps "Add Profile".
    let onAdd: () -> Void

    /// Called when the user taps "Edit" on a profile.
    let onEdit: (APIServerConfig) -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if configStore.configs.isEmpty {
                emptyState
            } else {
                profileRows
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("API Relay Profiles")
                .font(.title2.bold())

            Spacer()

            Button(action: onAdd) {
                Label("Add Profile", systemImage: "plus")
            }
            .buttonStyle(BorderedProminentButtonStyle())
        }
        .padding(16)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No Profiles")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Add an OpenAI-compatible relay server to start chatting.")
                .font(.callout)
                .foregroundColor(.secondary)
            Button("Add Profile", action: onAdd)
                .buttonStyle(BorderedProminentButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    private var profileRows: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(configStore.configs) { config in
                    ProfileRow(
                        config: config,
                        isActive: configStore.activeConfigID == config.id,
                        isTesting: appSettingViewModel.isTestingConnection
                            && configStore.activeConfigID == config.id,
                        onActivate: {
                            configStore.activeConfigID = config.id
                        },
                        onEdit: { onEdit(config) },
                        onDelete: { appSettingViewModel.delete(config) },
                        onFetchModels: { appSettingViewModel.fetchModels(for: config.id) },
                        onTest: { appSettingViewModel.testConnection(for: config) }
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Profile row

/// A single profile card in the list.
private struct ProfileRow: View {

    /// Profile being displayed.
    let config: APIServerConfig

    /// Whether this is the active profile.
    let isActive: Bool

    /// Whether a connection test is running for this row.
    let isTesting: Bool

    /// Make this the active profile.
    let onActivate: () -> Void

    /// Open the editor for this profile.
    let onEdit: () -> Void

    /// Delete this profile.
    let onDelete: () -> Void

    /// Fetch the model list for this profile.
    let onFetchModels: () -> Void

    /// Test connectivity for this profile.
    let onTest: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(config.displayName)
                    .font(.headline)

                if isActive {
                    Text("Active")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .help("Testing connection…")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(config.baseURL.isEmpty ? "No base URL set" : config.baseURL)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(config.apiKey.isEmpty ? "No API key set" : "API key: ••••••••")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(config.selectedModel.isEmpty
                     ? "No model selected"
                     : "Model: \(config.selectedModel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button(
                    config.availableModels.isEmpty ? "Fetch Models" : "\(config.availableModels.count) models",
                    action: onFetchModels
                )
                .buttonStyle(BorderedButtonStyle())
                .help("Fetch available models from the relay")

                Button("Test", action: onTest)
                    .buttonStyle(BorderedButtonStyle())
                    .help("Test API connection")

                Button("Edit", action: onEdit)
                    .buttonStyle(BorderedButtonStyle())

                Spacer()

                Button("Delete", action: onDelete)
                    .buttonStyle(BorderedButtonStyle())
                    .foregroundColor(.red)
            }
            .font(.callout)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Profile editor

/// Form for creating or editing a profile.
private struct ProfileEditView: View {

    // MARK: - Environment

    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel

    /// The draft being edited.
    @State private var draft: APIServerConfig

    /// Whether this is a brand-new profile.
    let isNew: Bool

    /// Save the draft.
    let onSave: (APIServerConfig) -> Void

    /// Cancel editing.
    let onCancel: () -> Void

    // MARK: - Initializers

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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Profile" : "Edit Profile")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Profile Name", text: $draft.name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Base URL", text: $draft.baseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .help("e.g. https://api.openai.com or https://relay.example.com/v1")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("API Key", text: $draft.apiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                // Model management section
                if !isNew {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()

                        Text("Models")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Selected Model", selection: $draft.selectedModel) {
                            if draft.availableModels.isEmpty {
                                Text("No models yet").tag("")
                            }
                            ForEach(draft.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .disabled(draft.availableModels.isEmpty)

                        HStack {
                            Button {
                                appSettingViewModel.fetchModels(for: draft.id)
                                // Pull updated models back after a brief delay.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    if let updated = configStore.configs.first(where: { $0.id == draft.id }) {
                                        draft = updated
                                    }
                                }
                            } label: {
                                Label("Fetch Models", systemImage: "arrow.clockwise")
                            }
                            .disabled(appSettingViewModel.isLoadingModels)

                            if appSettingViewModel.isLoadingModels {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(BorderedButtonStyle())

                Spacer()

                Button(action: save) {
                    Text(isNew ? "Add" : "Save")
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .onAppear {
            // For existing profiles, reflect any previously-fetched models.
            if let existing = configStore.configs.first(where: { $0.id == draft.id }) {
                draft = existing
            }
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func save() {
        // Normalize whitespace in key fields.
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(draft)
    }
}