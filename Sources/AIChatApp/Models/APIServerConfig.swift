import Foundation

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

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        selectedModel: String = "",
        availableModels: [String] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.selectedModel = selectedModel
        self.availableModels = availableModels
    }

    /// A friendly display name for UI lists.
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unnamed profile"
            : name
    }
}