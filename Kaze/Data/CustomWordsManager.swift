import Foundation
import Combine

/// Manages a user-defined list of custom words, names, abbreviations, and terms
/// that should be recognized accurately during transcription.
/// Stored as a JSON file in Application Support.
@MainActor
class CustomWordsManager: ObservableObject {
    @Published private(set) var words: [String] = []
    private let diskWriter: SerialDiskWriter<[String]>

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.fayazahmed.Kaze", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_words.json")
    }

    init() {
        diskWriter = SerialDiskWriter(url: Self.fileURL)
        loadFromDisk()
    }

    /// Adds a new word if it's not empty and not already in the list.
    func addWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Case-insensitive duplicate check
        guard !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        words.append(trimmed)
        saveToDisk()
    }

    /// Removes a word at the given index.
    func removeWord(at index: Int) {
        guard words.indices.contains(index) else { return }
        words.remove(at: index)
        saveToDisk()
    }

    /// Removes a word by value.
    func removeWord(_ word: String) {
        words.removeAll { $0 == word }
        saveToDisk()
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let snapshot = self.words
        Task { await diskWriter.enqueue(snapshot) }
    }

    private func loadFromDisk() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            words = try JSONDecoder().decode([String].self, from: data)
        } catch {
            print("CustomWordsManager: Failed to load: \(error)")
            words = []
        }
    }
}
