import Foundation
import Combine

/// Manages API relay profiles: creation, editing, deletion, activation,
/// connection testing, and model-list fetching.
///
/// Modern Swift Concurrency implementation:
/// - `@MainActor` keeps all published state on the main thread.
/// - Network calls `await` the actor-isolated `OpenAIService`.
@MainActor
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

    /// Combine subscriptions.
    private var cancellables = Set<AnyCancellable>()

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

        // Mirror store changes into this VM (one-way: store → VM).
        configStore.$configs
            .sink { [weak self] newConfigs in
                self?.configs = newConfigs
            }
            .store(in: &cancellables)
        configStore.$activeConfigID
            .sink { [weak self] newID in
                self?.activeConfigID = newID
            }
            .store(in: &cancellables)
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
        // `fetchModels` is async — hop to a Task from this non-async method.
        if config.availableModels.isEmpty {
            Task { await fetchModels(for: config.id) }
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
    func testConnection(for config: APIServerConfig) async {
        isTestingConnection = true
        statusMessage = nil
        statusIsError = false
        defer { isTestingConnection = false }

        do {
            let (models, _) = try await service.fetchModels(config: config)
            statusMessage = "✓ Connected — \(models.count) model(s) available."
            statusIsError = false
        } catch {
            statusMessage = "✗ Failed — \(error.localizedDescription)"
            statusIsError = true
        }
    }

    // MARK: - Model list

    /// Fetches the model list + dynamic prices for the given profile and
    /// persists them onto the stored config.
    func fetchModels(for configID: UUID) async {
        guard let config = configs.first(where: { $0.id == configID }) else {
            return
        }

        isLoadingModels = true
        statusMessage = nil
        statusIsError = false
        defer { isLoadingModels = false }

        do {
            let (models, prices) = try await service.fetchModels(config: config)

            // Normalize the base URL and persist models + dynamic prices.
            // `normalizedBaseURL` is an actor method — must `await`.
            guard let normalized = try? await service.normalizedBaseURL(from: config.baseURL) else {
                statusMessage = "Invalid base URL."
                statusIsError = true
                return
            }

            configStore.updateModels(
                models,
                prices: prices,
                normalizedBaseURL: normalized,
                for: configID
            )

            // Auto-select the first model if none is chosen yet.
            if let updated = configs.first(where: { $0.id == configID }),
               updated.selectedModel.isEmpty,
               let first = models.first {
                var selected = updated
                selected.selectedModel = first
                configStore.update(selected)
            }

            statusMessage = "Loaded \(models.count) model(s)."
            statusIsError = false

        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    /// Clears the transient status message (used when dismissing alerts).
    func clearStatus() {
        statusMessage = nil
        statusIsError = false
    }
}