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

        if let data = defaults.data(forKey: Self.configsKey),
           let decoded = try? JSONDecoder().decode([APIServerConfig].self, from: data) {
            self.configs = Self.migrateAndHydrate(decoded)
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
        KeychainService.delete(account: config.id.uuidString)
        configs.removeAll { $0.id == config.id }

        if activeConfigID == config.id {
            activeConfigID = configs.first?.id
        }
    }

    /// Replaces the whole profile list (used when importing a backup).
    func replaceAll(with new: [APIServerConfig]) {
        // Remove keychain entries for profiles that no longer exist.
        let incomingIDs = Set(new.map(\.id))
        for existing in configs where !incomingIDs.contains(existing.id) {
            KeychainService.delete(account: existing.id.uuidString)
        }

        // Restoring a sanitized backup must not wipe keys that still live in
        // this Mac's Keychain for the same profile UUID.
        var hydrated = new
        for index in hydrated.indices where hydrated[index].apiKey.isEmpty {
            if let key = KeychainService.load(account: hydrated[index].id.uuidString) {
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
        normalizedBaseURL: URL,
        for configID: UUID
    ) {
        guard let index = configs.firstIndex(where: { $0.id == configID }) else { return }
        configs[index].availableModels = models
        configs[index].modelPrices = prices
        configs[index].baseURL = normalizedBaseURL.absoluteString
    }

    // MARK: - Persistence

    private func persist() {
        // API keys live in the Keychain, never in UserDefaults / plaintext
        // files. Only blank a key in the encoded copy after the Keychain
        // confirmed it stored the secret; otherwise we would erase the last
        // remaining copy of the key on a transient Keychain failure.
        let sanitized = configs.map { config -> APIServerConfig in
            var copy = config
            if config.apiKey.isEmpty {
                KeychainService.delete(account: config.id.uuidString)
            } else if KeychainService.save(config.apiKey, account: config.id.uuidString) {
                copy.apiKey = ""
            }
            return copy
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.configsKey)
        // Synchronous flush so profiles survive an immediate quit / power loss.
        defaults.synchronize()
    }

    /// Decodes profiles that may still contain legacy plaintext keys in
    /// UserDefaults: migrates each key into the Keychain, then loads the
    /// current key from the Keychain so in-memory profiles stay usable.
    private static func migrateAndHydrate(_ raw: [APIServerConfig]) -> [APIServerConfig] {
        raw.map { config in
            var result = config

            if !config.apiKey.isEmpty {
                // Legacy plaintext from an older build: move it to the Keychain
                // before wiping it from the UserDefaults copy.
                if KeychainService.save(config.apiKey, account: config.id.uuidString) {
                    result.apiKey = ""
                }
            }

            // If a key is already in the Keychain (either just migrated or
            // written by a previous launch), hydrate the in-memory profile.
            if result.apiKey.isEmpty,
               let keychainKey = KeychainService.load(account: config.id.uuidString) {
                result.apiKey = keychainKey
            }

            return result
        }
    }
}
