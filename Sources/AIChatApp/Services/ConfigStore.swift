import Foundation

/// Persists the list of `APIServerConfig` profiles plus the currently
/// active profile id using `UserDefaults`.
///
/// Backed by a JSON-encoded array under a single key; safe for small
/// amounts of user configuration data.
final class ConfigStore: ObservableObject {

    // MARK: - Constants

    /// `UserDefaults` key encoding the full profile array.
    private static let configsKey = "configs"

    /// `UserDefaults` key recording the active profile UUID string.
    private static let activeIDKey = "activeConfigID"

    // MARK: - Published state

    /// All saved relay profiles, in user-defined order.
    @Published var configs: [APIServerConfig] {
        didSet { persist() }
    }

    /// The profile currently selected for chatting.
    @Published var activeConfigID: UUID? {
        didSet {
            UserDefaults.standard.set(
                activeConfigID?.uuidString,
                forKey: Self.activeIDKey
            )
        }
    }

    /// Convenience accessor for the active profile object.
    var activeConfig: APIServerConfig? {
        guard let id = activeConfigID else { return nil }
        return configs.first { $0.id == id }
    }

    // MARK: - Initializers

    init() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.configsKey),
           let decoded = try? JSONDecoder().decode([APIServerConfig].self, from: data) {
            self.configs = decoded
        } else {
            self.configs = []
        }

        if let stored = defaults.string(forKey: Self.activeIDKey),
           let id = UUID(uuidString: stored),
           self.configs.contains(where: { $0.id == id }) {
            self.activeConfigID = id
        } else {
            // Default to the first profile if one exists.
            self.activeConfigID = self.configs.first?.id
        }
    }

    // MARK: - CRUD operations

    /// Adds a new profile and makes it active.
    func add(_ config: APIServerConfig) {
        configs.append(config)
        activeConfigID = config.id
    }

    /// Updates a profile in place (matched by id).
    func update(_ config: APIServerConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[index] = config
    }

    /// Removes a profile (by id).
    ///
    /// If the removed profile was active, switches to the first remaining
    /// profile or clears the active selection.
    func delete(_ config: APIServerConfig) {
        configs.removeAll { $0.id == config.id }

        if activeConfigID == config.id {
            activeConfigID = configs.first?.id
        }
    }

    /// Refreshes the stored model list for a profile after a `fetchModels`
    /// call. Also normalizes the base URL to its canonical form.
    func updateModels(_ models: [String], normalizedBaseURL: URL, for configID: UUID) {
        guard let index = configs.firstIndex(where: { $0.id == configID }) else { return }
        configs[index].availableModels = models
        configs[index].baseURL = normalizedBaseURL.absoluteString
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: Self.configsKey)
    }
}