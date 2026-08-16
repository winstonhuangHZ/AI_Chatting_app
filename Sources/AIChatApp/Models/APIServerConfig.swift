import Foundation

/// Price for one model as reported by the relay (OpenRouter-style extension).
///
/// Many OpenAI-compatible relays (one-api / new-api / OpenRouter format)
/// include a `pricing` object on each model entry in `GET /v1/models`:
///   {"id":"gpt-4o-mini","pricing":{"prompt":0.15,"completion":0.6}}
/// Units are USD per 1M tokens.
struct ModelPrice: Codable, Hashable {
    /// USD per 1M input (prompt) tokens.
    var prompt: Double

    /// USD per 1M output (completion) tokens.
    var completion: Double

    /// Whether both prices are non-negative (sane).
    var isValid: Bool {
        prompt >= 0 && completion >= 0
    }
}

/// Represents a single OpenAI-compatible API relay server profile.
///
/// Stored in `UserDefaults` as JSON, so it conforms to `Codable` and
/// `Hashable`. It is identified by a stable `UUID`.
struct APIServerConfig: Identifiable, Codable, Hashable {

    // MARK: - Stored properties

    /// Stable identifier for this profile.
    var id: UUID

    /// Human-readable name for the profile (e.g. "Company Relay").
    var name: String

    /// The relay server root URL (e.g. `https://api.example.com`).
    ///
    /// The service layer normalizes trailing slashes and the `/v1` suffix.
    var baseURL: String

    /// Bearer token used to authenticate requests (`Authorization: Bearer ...`).
    var apiKey: String

    /// The model currently selected for this profile (e.g. `gpt-4o-mini`).
    var selectedModel: String

    /// Models reported by the relay's `GET /v1/models` endpoint.
    var availableModels: [String]

    /// Dynamic prices fetched from the relay (keyed by model id).
    /// Empty when the relay does not expose `pricing`.
    var modelPrices: [String: ModelPrice]

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        selectedModel: String = "",
        availableModels: [String] = [],
        modelPrices: [String: ModelPrice] = [:]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.modelPrices = modelPrices
    }

    /// A friendly display name for UI lists.
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unnamed profile"
            : name
    }

    // MARK: - Codable

    /// Custom decoding so profiles persisted *before* dynamic pricing support
    /// (without a `modelPrices` key) still decode correctly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        selectedModel = try container.decode(String.self, forKey: .selectedModel)
        availableModels = try container.decode([String].self, forKey: .availableModels)
        modelPrices = try container.decodeIfPresent([String: ModelPrice].self, forKey: .modelPrices) ?? [:]
    }
}