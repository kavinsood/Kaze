import Foundation
import Combine

// MARK: - Transcription Source

struct TranscriptionSource: Codable, Hashable, Identifiable {
    let bundleIdentifier: String?
    let name: String

    var id: String { storageKey }

    var storageKey: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier.lowercased()
        }
        return name.lowercased()
    }
}

// MARK: - TranscriptionRecord

struct TranscriptionRecord: Codable, Identifiable {
    let id: UUID
    let text: String
    let timestamp: Date
    let engine: String       // "whisper" identifies Cloudflare-hosted Whisper in this fork.
    let wasEnhanced: Bool
    let wordCount: Int
    let speechDuration: TimeInterval
    let sourceName: String?
    let sourceBundleIdentifier: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case timestamp
        case engine
        case wasEnhanced
        case wordCount
        case speechDuration
        case sourceName
        case sourceBundleIdentifier
    }

    init(
        text: String,
        engine: TranscriptionEngine,
        wasEnhanced: Bool,
        speechDuration: TimeInterval = 0,
        source: TranscriptionSource? = nil,
        timestamp: Date = Date()
    ) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.engine = engine.rawValue
        self.wasEnhanced = wasEnhanced
        self.wordCount = text.kazeWordCount
        self.speechDuration = speechDuration
        self.sourceName = source?.name
        self.sourceBundleIdentifier = source?.bundleIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? TranscriptionEngine.whisper.rawValue
        wasEnhanced = try container.decodeIfPresent(Bool.self, forKey: .wasEnhanced) ?? false
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? text.kazeWordCount
        speechDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .speechDuration) ?? 0
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        sourceBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(engine, forKey: .engine)
        try container.encode(wasEnhanced, forKey: .wasEnhanced)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(speechDuration, forKey: .speechDuration)
        try container.encodeIfPresent(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(sourceBundleIdentifier, forKey: .sourceBundleIdentifier)
    }

    var source: TranscriptionSource? {
        guard let sourceName else { return nil }
        return TranscriptionSource(bundleIdentifier: sourceBundleIdentifier, name: sourceName)
    }
}

// MARK: - Transcription Stats

struct TranscriptionStatsSnapshot: Codable {
    struct DailyActivity: Codable, Identifiable {
        let date: Date
        var words: Int
        var speechDuration: TimeInterval
        var sessions: Int

        var id: Date { date }
    }

    struct SourceUsage: Codable, Identifiable {
        let id: String
        let name: String
        let bundleIdentifier: String?
        var words: Int
        var speechDuration: TimeInterval
        var sessions: Int
        var lastUsedAt: Date
    }

    struct DailySourceUsage: Codable, Identifiable {
        let date: Date
        let sourceID: String
        let name: String
        let bundleIdentifier: String?
        var words: Int
        var speechDuration: TimeInterval
        var sessions: Int

        var id: String {
            "\(sourceID)|\(date.timeIntervalSinceReferenceDate)"
        }
    }

    struct WindowedSummary {
        let totalWords: Int
        let totalSpeechDuration: TimeInterval
        let totalSessions: Int
        let activeDays: Int
        let dailyActivity: [DailyActivity]
        let topSources: [SourceUsage]

        var averageWordsPerMinute: Double? {
            guard totalSpeechDuration > 0 else { return nil }
            return Double(totalWords) / (totalSpeechDuration / 60)
        }

        var estimatedTimeSaved: TimeInterval {
            let typingDuration = Double(totalWords) / TranscriptionStatsSnapshot.typingBaselineWPM * 60
            return max(typingDuration - totalSpeechDuration, 0)
        }
    }

    static let typingBaselineWPM = 40.0
    static let defaultWindowDays = 30

    var totalWords: Int = 0
    var totalSpeechDuration: TimeInterval = 0
    var totalSessions: Int = 0
    var dailyActivity: [DailyActivity] = []
    var sources: [SourceUsage] = []
    var dailySources: [DailySourceUsage] = []

    var averageWordsPerMinute: Double? {
        guard totalSpeechDuration > 0 else { return nil }
        return Double(totalWords) / (totalSpeechDuration / 60)
    }

    var estimatedTimeSaved: TimeInterval {
        let typingDuration = Double(totalWords) / Self.typingBaselineWPM * 60
        return max(typingDuration - totalSpeechDuration, 0)
    }

    var activeDaysCount: Int {
        dailyActivity.reduce(into: 0) { count, day in
            if day.sessions > 0 {
                count += 1
            }
        }
    }

    var topSources: [SourceUsage] {
        sources
            .filter { $0.words > 0 }
            .sorted {
                if $0.words != $1.words {
                    return $0.words > $1.words
                }
                return $0.lastUsedAt > $1.lastUsedAt
            }
    }

    func summary(
        forLast days: Int,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) -> WindowedSummary {
        let endDate = calendar.startOfDay(for: now)
        guard let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: endDate) else {
            return WindowedSummary(
                totalWords: 0,
                totalSpeechDuration: 0,
                totalSessions: 0,
                activeDays: 0,
                dailyActivity: [],
                topSources: []
            )
        }

        let windowedActivity = dailyActivity.filter { day in
            let date = calendar.startOfDay(for: day.date)
            return date >= startDate && date <= endDate
        }

        let windowedDailySources = dailySources.filter { entry in
            let date = calendar.startOfDay(for: entry.date)
            return date >= startDate && date <= endDate
        }

        var sourceTotals: [String: SourceUsage] = [:]
        for entry in windowedDailySources {
            if var existing = sourceTotals[entry.sourceID] {
                existing.words += entry.words
                existing.speechDuration += entry.speechDuration
                existing.sessions += entry.sessions
                existing.lastUsedAt = max(existing.lastUsedAt, entry.date)
                sourceTotals[entry.sourceID] = existing
            } else {
                sourceTotals[entry.sourceID] = SourceUsage(
                    id: entry.sourceID,
                    name: entry.name,
                    bundleIdentifier: entry.bundleIdentifier,
                    words: entry.words,
                    speechDuration: entry.speechDuration,
                    sessions: entry.sessions,
                    lastUsedAt: entry.date
                )
            }
        }

        let sortedSources = sourceTotals.values.sorted {
            if $0.words != $1.words {
                return $0.words > $1.words
            }
            return $0.lastUsedAt > $1.lastUsedAt
        }

        return WindowedSummary(
            totalWords: windowedActivity.reduce(0) { $0 + $1.words },
            totalSpeechDuration: windowedActivity.reduce(0) { $0 + $1.speechDuration },
            totalSessions: windowedActivity.reduce(0) { $0 + $1.sessions },
            activeDays: windowedActivity.reduce(0) { $0 + ($1.sessions > 0 ? 1 : 0) },
            dailyActivity: windowedActivity.sorted { $0.date < $1.date },
            topSources: sortedSources
        )
    }

    mutating func ingest(_ record: TranscriptionRecord, calendar: Calendar = .autoupdatingCurrent) {
        totalWords += record.wordCount
        totalSpeechDuration += record.speechDuration
        totalSessions += 1

        let dayDate = calendar.startOfDay(for: record.timestamp)
        if let index = dailyActivity.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: dayDate) }) {
            dailyActivity[index].words += record.wordCount
            dailyActivity[index].speechDuration += record.speechDuration
            dailyActivity[index].sessions += 1
        } else {
            dailyActivity.append(
                DailyActivity(
                    date: dayDate,
                    words: record.wordCount,
                    speechDuration: record.speechDuration,
                    sessions: 1
                )
            )
        }
        dailyActivity.sort { $0.date < $1.date }

        guard let source = record.source else { return }

        if let index = sources.firstIndex(where: { $0.id == source.storageKey }) {
            sources[index].words += record.wordCount
            sources[index].speechDuration += record.speechDuration
            sources[index].sessions += 1
            sources[index].lastUsedAt = max(sources[index].lastUsedAt, record.timestamp)
        } else {
            sources.append(
                SourceUsage(
                    id: source.storageKey,
                    name: source.name,
                    bundleIdentifier: source.bundleIdentifier,
                    words: record.wordCount,
                    speechDuration: record.speechDuration,
                    sessions: 1,
                    lastUsedAt: record.timestamp
                )
            )
        }

        if let index = dailySources.firstIndex(where: {
            $0.sourceID == source.storageKey && calendar.isDate($0.date, inSameDayAs: dayDate)
        }) {
            dailySources[index].words += record.wordCount
            dailySources[index].speechDuration += record.speechDuration
            dailySources[index].sessions += 1
        } else {
            dailySources.append(
                DailySourceUsage(
                    date: dayDate,
                    sourceID: source.storageKey,
                    name: source.name,
                    bundleIdentifier: source.bundleIdentifier,
                    words: record.wordCount,
                    speechDuration: record.speechDuration,
                    sessions: 1
                )
            )
        }
        dailySources.sort {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.sourceID < $1.sourceID
        }
    }

    mutating func backfillDailySources(
        from records: [TranscriptionRecord],
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard dailySources.isEmpty else { return }

        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let source = record.source else { continue }
            let dayDate = calendar.startOfDay(for: record.timestamp)

            if let index = dailySources.firstIndex(where: {
                $0.sourceID == source.storageKey && calendar.isDate($0.date, inSameDayAs: dayDate)
            }) {
                dailySources[index].words += record.wordCount
                dailySources[index].speechDuration += record.speechDuration
                dailySources[index].sessions += 1
            } else {
                dailySources.append(
                    DailySourceUsage(
                        date: dayDate,
                        sourceID: source.storageKey,
                        name: source.name,
                        bundleIdentifier: source.bundleIdentifier,
                        words: record.wordCount,
                        speechDuration: record.speechDuration,
                        sessions: 1
                    )
                )
            }
        }

        dailySources.sort {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.sourceID < $1.sourceID
        }
    }
}

// MARK: - Serial Disk Writer

/// A single-writer actor that serializes all JSON persistence.
/// Each write awaits the previous one, and a short debounce coalesces rapid mutations
/// so only the latest snapshot hits disk.
actor SerialDiskWriter<T: Encodable> {
    private let url: URL
    private var pendingValue: T?
    private var writeInFlight = false
    private static var debounceNanoseconds: UInt64 { 150_000_000 } // 150ms

    init(url: URL) {
        self.url = url
    }

    func enqueue(_ value: T) {
        pendingValue = value
        guard !writeInFlight else { return }
        writeInFlight = true
        Task { self.drainLoop() }
    }

    private func drainLoop() {
        while let value = pendingValue {
            pendingValue = nil
            do {
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                print("SerialDiskWriter: Failed to save to \(url.lastPathComponent): \(error)")
            }
            // Short debounce: if another write was enqueued during encoding, coalesce.
            if pendingValue == nil {
                break
            }
        }
        writeInFlight = false
    }
}

// MARK: - TranscriptionHistoryManager

/// Manages a persistent history of the last 50 transcriptions.
/// Stored as a JSON file in Application Support.
@MainActor
class TranscriptionHistoryManager: ObservableObject {
    @Published private(set) var records: [TranscriptionRecord] = []
    @Published private(set) var stats = TranscriptionStatsSnapshot()

    private static let maxRecords = 50
    private let diskWriter: SerialDiskWriter<[TranscriptionRecord]>
    private let statsWriter: SerialDiskWriter<TranscriptionStatsSnapshot>

    private static var historyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.fayazahmed.Kaze", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private static var statsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.fayazahmed.Kaze", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-stats.json")
    }

    init() {
        diskWriter = SerialDiskWriter(url: Self.historyFileURL)
        statsWriter = SerialDiskWriter(url: Self.statsFileURL)
        loadFromDisk()
        loadStatsFromDisk()
        migrateStatsIfNeeded()
    }

    /// Adds a new transcription record. Keeps only the most recent 50.
    func addRecord(_ record: TranscriptionRecord) {
        guard !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        stats.ingest(record)
        saveToDisk()
        saveStatsToDisk()
    }

    /// Deletes a single record by ID.
    func deleteRecord(id: UUID) {
        records.removeAll { $0.id == id }
        saveToDisk()
    }

    /// Clears all history.
    func clearHistory() {
        records.removeAll()
        saveToDisk()
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let snapshot = self.records
        Task { await diskWriter.enqueue(snapshot) }
    }

    private func saveStatsToDisk() {
        let snapshot = self.stats
        Task { await statsWriter.enqueue(snapshot) }
    }

    private func loadFromDisk() {
        let url = Self.historyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
        } catch {
            print("TranscriptionHistory: Failed to load: \(error)")
            records = []
        }
    }

    private func loadStatsFromDisk() {
        let url = Self.statsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            stats = try JSONDecoder().decode(TranscriptionStatsSnapshot.self, from: data)
        } catch {
            print("TranscriptionStats: Failed to load: \(error)")
            stats = TranscriptionStatsSnapshot()
        }
    }

    private func migrateStatsIfNeeded() {
        let dailySourcesWasEmpty = stats.dailySources.isEmpty
        stats.backfillDailySources(from: records)
        if dailySourcesWasEmpty && !stats.dailySources.isEmpty {
            saveStatsToDisk()
        }
    }
}

// MARK: - Static Relative Date Formatting

extension Date {
    /// Cached DateFormatter to avoid re-creating one per cell (Fix #7).
    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Returns a static relative string like "Just now", "3 min ago", "2 hr ago", "Yesterday", etc.
    /// Unlike SwiftUI's `Text(_:style: .relative)`, this does not live-update.
    var relativeString: String {
        let now = Date()
        let seconds = Int(now.timeIntervalSince(self))

        if seconds < 60 {
            return "Just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) hr ago"
        }

        let days = hours / 24
        if days == 1 {
            return "Yesterday"
        }
        if days < 7 {
            return "\(days) days ago"
        }

        return Self.mediumDateFormatter.string(from: self)
    }
}

private extension String {
    var kazeWordCount: Int {
        var total = 0
        enumerateSubstrings(in: startIndex..<endIndex, options: [.byWords, .localized]) { _, _, _, _ in
            total += 1
        }
        return total
    }
}
