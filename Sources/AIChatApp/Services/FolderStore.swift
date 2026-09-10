import Foundation

/// Persists sidebar folders (user-created or created by the AI classifier).
final class FolderStore: ObservableObject {
    private static let key = "chatFolders.v1"

    @Published var folders: [ChatFolder] {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ChatFolder].self, from: data) {
            self.folders = decoded.sorted { $0.createdAt < $1.createdAt }
        } else {
            self.folders = []
        }
    }

    /// Returns the existing folder with this name (case-insensitive) or creates it.
    @discardableResult
    func folder(named rawName: String) -> ChatFolder? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = folders.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing
        }
        let folder = ChatFolder(name: name)
        folders.append(folder)
        return folder
    }

    func rename(_ folder: ChatFolder, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].name = name
    }

    func delete(_ folder: ChatFolder) {
        folders.removeAll { $0.id == folder.id }
    }

    func replaceAll(with new: [ChatFolder]) {
        folders = new
    }

    func names() -> [String] {
        folders.map(\.name)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
