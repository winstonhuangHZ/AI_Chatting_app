import Foundation
import Combine

/// Manages API relay profiles: creation, editing, deletion, activation,
/// connection testing, and model-list fetching.
///
/// Uses the callback-based `OpenAIService` (no async/await) so it compiles
/// with older SDKs. All network completions arrive on the main queue.
final class AppSettingViewModel: ObservableObject {

    // MARK: - Dependencies

    private let configStore: ConfigStore
    private let service = OpenAIService()

    // MARK: - Published state

    /// All saved profiles (delegated to the shared store).
    @Published var configs: [APIServerConfig] = []

    /// The active profile id (delegated to the shared store).
    @Published var activeConfigID: UUID?

    /// `true` while a `GET /v1/models` request is in flight.
    @Published var isLoadingModels = false

    /// `true` while a connection test is in flight.
    @Published var isTestingConnection = false

    /// Last user-facing status message (success or failure).
    @Published var statusMessage: String?

    /// `true` when the status message represents an error.
    @Published var statusIsError = false

    // MARK: - Convenience

    /// The active profile object, if any.
    var activeConfig: APIServerConfig? {
        guard let id = activeConfigID else { return nil }
        return configs.first { $0.id == id }
    }

    // MARK: - Initializers

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.configs = configStore.configs
        self.activeConfigID = configStore.activeConfigID

        // Mirror store changes into this VM for one-way data flow.
        configStore.$configs
            .assign(to: &$configs)
        configStore.$activeConfigID
            .assign(to: &$activeConfigID)
    }

    // MARK: - CRUD

    /// Adds a new profile and selects it.
    func add(_ config: APIServerConfig) {
        configStore.add(config)
    }

    /// Updates an existing profile.
    func update(_ config: APIServerConfig) {
        configStore.update(config)
        // Auto-fetch models if the profile has none cached.
        if config.availableModels.isEmpty {
            fetchModels(for: config.id)
        }
    }

    /// Removes a profile.
    func delete(_ config: APIServerConfig) {
        configStore.delete(config)
    }

    /// Sets the active profile.
    func setActive(_ config: APIServerConfig) {
        configStore.activeConfigID = config.id
    }

    // MARK: - Connection testing

    /// Performs a lightweight round-trip against `GET /v1/models` to verify
    /// credentials and reachability, without persisting the model list.
    func testConnection(for config: APIServerConfig) {
        isTestingConnection = true
        statusMessage = nil
        statusIsError = false

        service.fetchModels(config: config) { [weak self] result in
            guard let self else { return }
            self.isTestingConnection = false

            switch result {
            case .success(let models):
                self.statusMessage = "✓ Connected — \(models.count) model(s) available."
                self.statusIsError = false
            case .failure(let error):
                self.statusMessage = "✗ Failed — \(error.localizedDescription)"
                self.statusIsError = true
            }
        }
    }

    // MARK: - Model list

    /// Fetches the model list for the given profile and persists it onto
    /// the stored config.
    func fetchModels(for configID: UUID) {
        guard let config = configs.first(where: { $0.id == configID }) else {
            return
        }

        isLoadingModels = true
        statusMessage = nil
        statusIsError = false

        service.fetchModels(config: config) { [weak self] result in
            guard let self else { return }
            self.isLoadingModels = false

            switch result {
            case .success(let models):
                // Normalize the base URL and persist models.
                guard let normalized = try? self.service.normalizedBaseURL(from: config.baseURL) else {
                    self.statusMessage = "Invalid base URL."
                    self.statusIsError = true
                    return
                }

                self.configStore.updateModels(
                    models,
                    normalizedBaseURL: normalized,
                    for: configID
                )

                // Auto-select the first model if none is chosen yet.
                if let updated = self.configs.first(where: { $0.id == configID }),
                   updated.selectedModel.isEmpty,
                   let first = models.first {
                    var selected = updated
                    selected.selectedModel = first
                    self.configStore.update(selected)
                }

                self.statusMessage = "Loaded \(models.count) model(s)."
                self.statusIsError = false

            case .failure(let error):
                self.statusMessage = error.localizedDescription
                self.statusIsError = true
            }
        }
    }

    /// Clears the transient status message (used when dismissing alerts).
    func clearStatus() {
        statusMessage = nil
        statusIsError = false
    }
}