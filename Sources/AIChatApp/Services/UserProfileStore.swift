import Foundation

/// A single learned or manually-added user preference.
struct UserPreference: Identifiable, Codable, Hashable {
    /// Stable id.
    var id: UUID

    /// Category/tag, e.g. "language", "tone", "topic", "location".
    var category: String

    /// The actual preference value, e.g. "简洁中文", "Python", "深度技术分析".
    var value: String

    init(id: UUID = UUID(), category: String = "", value: String = "") {
        self.id = id
        self.category = category
        self.value = value
    }
}

/// Persists the user's learned/edited profile (preferences) in `UserDefaults`,
/// and provides helpers to encode/decode it into the system prompt payload.
final class UserProfileStore: ObservableObject {

    // MARK: - Constants

    private static let key = "userProfile.preferences.v1"

    // MARK: - Published state

    /// All known preferences.
    @Published var preferences: [UserPreference] {
        didSet { persist() }
    }

    // MARK: - Initializers

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([UserPreference].self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = []
        }
    }

    // MARK: - CRUD

    /// Adds or updates a preference (matched by category+value).
    func upsert(category: String, value: String) {
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty, !value.isEmpty else { return }

        if let idx = preferences.firstIndex(where: { $0.category == category && $0.value == value }) {
            preferences[idx].value = value
            return
        }
        preferences.append(UserPreference(category: category, value: value))
    }

    /// Removes a single preference.
    func remove(_ preference: UserPreference) {
        preferences.removeAll { $0.id == preference.id }
    }

    /// Replaces the whole set (used when parsing a batch from the model).
    func replaceAll(with new: [UserPreference]) {
        preferences = new
    }

    // MARK: - Encoding for the prompt

    /// JSON snapshot of all preferences (or nil when empty).
    var jsonPayload: String? {
        guard !preferences.isEmpty else { return nil }

        let payload: [[String: String]] = preferences.map {
            ["category": $0.category, "value": $0.value]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// Parses a `<!-- PERSONALIZATION: {...} -->` block from an assistant reply.
    /// Returns the parsed preferences array (or nil if absent/invalid).
    static func parse(from reply: String) -> [UserPreference]? {
        // Locate the marker: <!-- PERSONALIZATION: ... -->
        guard let lowerBound = reply.range(of: "<!-- PERSONALIZATION:") else { return nil }
        let afterWrapper = reply[lowerBound.upperBound...]
        guard let endOfBlock = afterWrapper.range(of: "-->") else { return nil }

        let jsonPart = afterWrapper[..<endOfBlock.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The payload may be JSON or JSON inside backticks.
        let cleaned = jsonPart
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = json["preferences"] as? [[String: Any]] else {
            return nil
        }

        var result: [UserPreference] = []
        for p in prefs {
            guard let category = p["category"] as? String,
                  let value = p["value"] as? String,
                  !category.isEmpty, !value.isEmpty else { continue }
            result.append(UserPreference(category: category, value: value))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.key)
        defaults.synchronize()
    }
}