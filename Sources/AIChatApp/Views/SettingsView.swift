import SwiftUI
import AppKit

/// Settings window: manages API relay profiles (add / edit / delete),
/// connection testing, and model list fetching.
///
/// Uses only macOS 10.15-compatible SwiftUI API — no SF Symbols, no `if let`
/// in ViewBuilders, explicit `self.` in closures (Swift 5.2 rules).
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
            if self.editingConfig != nil {
                ProfileEditView(
                    config: self.editingConfig!,
                    isNew: self.isAddingNew,
                    onSave: { updated in
                        if self.isAddingNew {
                            self.appSettingViewModel.add(updated)
                        } else {
                            self.appSettingViewModel.update(updated)
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
                        self.isAddingNew = true
                        self.editingConfig = APIServerConfig(name: "New Profile")
                    },
                    onEdit: { config in
                        self.isAddingNew = false
                        self.editingConfig = config
                    }
                )
            }
        }
        .frame(width: 520, height: 440)
        .alert(isPresented: self.$showStatusAlert) {
            Alert(
                title: Text(self.appSettingViewModel.statusIsError ? "Operation Failed" : "Success"),
                message: Text(self.appSettingViewModel.statusMessage ?? ""),
                dismissButton: .default(Text("OK")) {
                    self.appSettingViewModel.clearStatus()
                }
            )
        }
        .onReceive(self.appSettingViewModel.$statusMessage) { message in
            if message != nil {
                self.showStatusAlert = true
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
            self.header

            Divider()

            if self.configStore.configs.isEmpty {
                self.emptyState
            } else {
                self.profileRows
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("API Relay Profiles")
                .font(.system(size: 18, weight: .semibold))

            Spacer()

            Button(action: self.onAdd) {
                Text("＋ Add Profile")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(BorderedButtonStyle())
        }
        .padding(16)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("📡")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("No Profiles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Add an OpenAI-compatible relay server to start chatting.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Button("Add Profile", action: self.onAdd)
                .buttonStyle(BorderedButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    private var profileRows: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(self.configStore.configs) { config in
                    ProfileRow(
                        config: config,
                        isActive: self.configStore.activeConfigID == config.id,
                        isTesting: self.appSettingViewModel.isTestingConnection
                            && self.configStore.activeConfigID == config.id,
                        onActivate: {
                            self.configStore.activeConfigID = config.id
                        },
                        onEdit: {
                            self.onEdit(config)
                        },
                        onDelete: {
                            self.appSettingViewModel.delete(config)
                        },
                        onFetchModels: {
                            self.appSettingViewModel.fetchModels(for: config.id)
                        },
                        onTest: {
                            self.appSettingViewModel.testConnection(for: config)
                        }
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
                Text(self.config.displayName)
                    .font(.system(size: 14, weight: .semibold))

                if self.isActive {
                    Text("Active")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                if self.isTesting {
                    Text("…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(self.config.baseURL.isEmpty ? "No base URL set" : self.config.baseURL)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(self.config.apiKey.isEmpty ? "No API key set" : "API key: ••••••••")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(self.config.selectedModel.isEmpty
                     ? "No model selected"
                     : "Model: \(self.config.selectedModel)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button(
                    self.config.availableModels.isEmpty ? "Fetch Models" : "\(self.config.availableModels.count) models",
                    action: self.onFetchModels
                )
                .buttonStyle(BorderedButtonStyle())

                Button("Test", action: self.onTest)
                    .buttonStyle(BorderedButtonStyle())

                Button("Edit", action: self.onEdit)
                    .buttonStyle(BorderedButtonStyle())

                Spacer()

                Button("Delete", action: self.onDelete)
                    .buttonStyle(BorderedButtonStyle())
                    .foregroundColor(.red)
            }
            .font(.system(size: 12))
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
            Text(self.isNew ? "Add Profile" : "Edit Profile")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile Name")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("Profile Name", text: self.$draft.name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("Base URL", text: self.$draft.baseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    SecureField("API Key", text: self.$draft.apiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                // Model management section (existing profiles only)
                if !self.isNew {
                    self.modelSection
                }
            }

            HStack {
                Button("Cancel", action: self.onCancel)
                    .buttonStyle(BorderedButtonStyle())

                Spacer()

                Button(action: {
                    self.save()
                }) {
                    Text(self.isNew ? "Add" : "Save")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(!self.isValid)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .onAppear {
            // For existing profiles, reflect any previously-fetched models.
            if let existing = self.configStore.configs.first(where: { $0.id == self.draft.id }) {
                self.draft = existing
            }
        }
    }

    // MARK: - Model section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Models")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Picker("Selected Model", selection: self.$draft.selectedModel) {
                    if self.draft.availableModels.isEmpty {
                        Text("No models yet").tag("")
                    }
                    ForEach(self.draft.availableModels, id: \.self) { model in
                        // 🖼 marks multimodal (vision) models.
                        Text(MultimodalSupport.displayName(model)).tag(model)
                    }
                }
                .disabled(self.draft.availableModels.isEmpty)

                Text("🖼 = multimodal (vision) model")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Fetch Models") {
                    self.appSettingViewModel.fetchModels(for: self.draft.id)
                    // Pull updated models back after a brief delay.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if let updated = self.configStore.configs.first(where: { $0.id == self.draft.id }) {
                            self.draft = updated
                        }
                    }
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(self.appSettingViewModel.isLoadingModels)

                if self.appSettingViewModel.isLoadingModels {
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !self.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !self.draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func save() {
        // Normalize whitespace in key fields.
        self.draft.name = self.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.draft.baseURL = self.draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onSave(self.draft)
    }
}