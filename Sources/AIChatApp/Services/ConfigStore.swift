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
            let defaults = UserDefaults.standard
            defaults.set(
                activeConfigID?.uuidString,
                forKey: Self.activeIDKey
            )
            defaults.synchronize()
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

        var keychainSecrets = KeychainService.loadSecrets() ?? [:]
        if let data = defaults.data(forKey: Self.configsKey),
           let decoded = try? JSONDecoder().decode([APIServerConfig].self, from: data) {
            var hydrated = decoded
            for index in hydrated.indices {
                let account = hydrated[index].id.uuidString
                if let key = keychainSecrets[account] {
                    hydrated[index].apiKey = key
                } else if !hydrated[index].apiKey.isEmpty {
                    // Legacy plaintext stored in UserDefaults by an older build.
                    keychainSecrets[account] = hydrated[index].apiKey
                } else if let legacy = KeychainService.load(account: account) {
                    // Very old per-profile Keychain entries from the first
                    // Keychain rollout; fold them into the single map.
                    keychainSecrets[account] = legacy
                    hydrated[index].apiKey = legacy
                }
            }
            self.configs = hydrated
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

        // Immediately rewrite the preferences without plaintext keys so the
        // migration does not wait for the next unrelated profile change.
        persist()
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

    /// Replaces the whole profile list (used when importing a backup).
    func replaceAll(with new: [APIServerConfig]) {
        // Restoring a sanitized backup must not wipe keys that still live in
        // this Mac's Keychain for the same profile UUID. Stale keys for removed
        // profiles are dropped by the persist pass.
        let keychainSecrets = KeychainService.loadSecrets() ?? [:]
        var hydrated = new
        for index in hydrated.indices where hydrated[index].apiKey.isEmpty {
            if let key = keychainSecrets[hydrated[index].id.uuidString] {
                hydrated[index].apiKey = key
            }
        }

        configs = hydrated
        activeConfigID = configs.first?.id
    }

    /// Refreshes the stored model list + dynamic prices for a profile after a
    /// `fetchModels` call. Also normalizes the base URL to its canonical form.
    func updateModels(
        _ models: [String],
        prices: [String: ModelPrice],
        contextWindows: [String: Int] = [:],
        normalizedBaseURL: URL,
        for configID: UUID
    ) {
        guard let index = configs.firstIndex(where: { $0.id == configID }) else { return }
        configs[index].availableModels = models
        configs[index].modelPrices = prices
        configs[index].modelContextWindows = contextWindows
        configs[index].baseURL = normalizedBaseURL.absoluteString
    }

    /// Persists a per-model vision override ("always send images").
    func setVisionOverride(_ enabled: Bool?, for model: String, configID: UUID) {
        guard !model.isEmpty,
              let index = configs.firstIndex(where: { $0.id == configID }) else { return }
        if let enabled {
            configs[index].modelVisionOverrides[model] = enabled
        } else {
            configs[index].modelVisionOverrides.removeValue(forKey: model)
        }
    }

    // MARK: - Persistence

    private func persist() {
        // API keys live in the Keychain, never in UserDefaults / plaintext
        // files. Only blank a key in the encoded copy after the Keychain
        // confirmed it stored the secret; otherwise we would erase the last
        // remaining copy of the key on a transient Keychain failure.
        var secrets: [String: String] = [:]
        for config in configs where !config.apiKey.isEmpty {
            secrets[config.id.uuidString] = config.apiKey
        }
        // Persist the actual map copy; if writing fails keep the in-memory key.
        if !secrets.isEmpty {
            guard KeychainService.saveSecrets(secrets) else { return }
        } else {
            KeychainService.deleteSecrets()
        }

        // Encode a sanitized copy: the loaded keys stay in memory, but the
        // UserDefaults payload never contains plaintext secrets.
        let sanitized = configs.map { config -> APIServerConfig in
            var copy = config
            copy.apiKey = ""
            return copy
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.configsKey)
        // Synchronous flush so profiles survive an immediate quit / power loss.
        defaults.synchronize()
    }

}
