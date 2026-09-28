import AppKit
import Combine
import Foundation

/// A job is the source of truth. History is only a convenient, bounded view of completed text.
enum RecordingStatus: String, Codable {
    case recording, pending, transcribing, waitingToRetry, failed, ready, delivered
}

struct RecordingJob: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var status: RecordingStatus
    var language: String
    var prompt: String?
    var processedBytes: UInt64 = 0
    var expectedBytes: UInt64?
    var transcript: String = ""
    var attempt: Int = 0
    var nextAttempt: Date?
    var error: String?
    var captureWarning: String?
}

enum RecordingVaultError: LocalizedError {
    case missingAudio, invalidAudio, changedFormat, recordingTooLarge

    var errorDescription: String? {
        switch self {
        case .missingAudio: return "The local recording file is missing."
        case .invalidAudio: return "The saved recording is incomplete or unreadable."
        case .changedFormat: return "The microphone's audio format changed during recording; the captured portion was retained."
        case .recordingTooLarge: return "The recording has reached the local file format limit; the captured portion was retained."
        }
    }
}

/// Disk-first mono 16-bit PCM. The 16-byte header is written before any samples:
/// "KAZEPCM1" + little-endian UInt32 sample rate + reserved UInt32.
/// A crashed process leaves a readable prefix even if the last write was interrupted.
final class RecordingWriter {
    static let headerSize: UInt64 = 16
    private let handle: FileHandle
    private(set) var sampleRate: UInt32 = 0
    private var closed = false

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw RecordingVaultError.missingAudio
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("KAZEPCM1".utf8) + Data(repeating: 0, count: 8))
        try handle.synchronize()
    }

    func append(_ samples: [Float], sampleRate rate: Double) throws {
        guard !closed, rate.isFinite, rate >= 8_000, rate <= 192_000 else {
            throw RecordingVaultError.invalidAudio
        }
        let rounded = UInt32(rate.rounded())
        if sampleRate == 0 {
            sampleRate = rounded
            try handle.seek(toOffset: 8)
            var little = rounded.littleEndian
            try withUnsafeBytes(of: &little) { try handle.write(contentsOf: Data($0)) }
            try handle.seekToEnd()
            try handle.synchronize()
        } else if sampleRate != rounded {
            throw RecordingVaultError.changedFormat
        }
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples {
            let value = sample.isFinite ? min(max(sample, -1), 1) : 0
            pcm.append(Int16(value * Float(Int16.max)).littleEndian)
        }
        try pcm.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        // The journal is flushed on every capture callback, not just on hotkey release.
        try handle.synchronize()
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        var firstError: Error?
        do { try handle.synchronize() } catch { firstError = error }
        do { try handle.close() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }
}

@MainActor
final class RecordingVault: ObservableObject {
    @Published private(set) var jobs: [RecordingJob] = []
    var onReady: ((UUID, String) -> Void)?
    var onFailure: ((UUID, String, Bool) -> Void)?

    private let root: URL
    private let client: CloudflareTranscriptionClient
    private var worker: Task<Void, Never>?
    private var wakeTimer: Task<Void, Never>?
    private let fileManager = FileManager.default
    // Short, independent WAV files keep request memory bounded, regardless of recording length.
    private static let chunkSeconds: UInt64 = 30

    init(root: URL? = nil, client: CloudflareTranscriptionClient = .init()) {
        self.client = client
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("com.kavin.KazeCloud/Recordings", isDirectory: true)
        do {
            try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
            try loadAndRecover()
        } catch {
            // Do not silently start a session if the vault is unavailable.
            storageError = error.localizedDescription
        }
    }

    private(set) var storageError: String?

    func startRecovery() { schedule() }

    func begin(language: String, prompt: String?) throws -> (RecordingJob, RecordingWriter) {
        if let storageError { throw NSError(domain: "KazeRecordingVault", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: storageError]) }
        let job = RecordingJob(id: UUID(), createdAt: Date(), status: .recording,
                               language: language, prompt: prompt)
        let directory = directoryFor(job.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        do {
            try save(job) // manifest first: no audio without a discoverable job
            let writer = try RecordingWriter(url: audioURL(job.id))
            jobs.insert(job, at: 0)
            return (job, writer)
        } catch {
            // Preserve a possibly created manifest rather than hiding an orphaned job.
            throw error
        }
    }

    func finish(id: UUID, writer: RecordingWriter, warning: String? = nil) throws {
        var closeError: Error?
        do { try writer.close() } catch { closeError = error }
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.expectedBytes = (try? audioInfo(audioURL(id)))?.1
        let issue = warning ?? closeError?.localizedDescription
        job.captureWarning = issue
        job.status = issue == nil ? .pending : .failed
        job.error = issue
        try update(job)
        if let closeError { throw closeError }
        if issue == nil { schedule() }
    }

    func retry(id: UUID) throws {
        guard var job = jobs.first(where: { $0.id == id }),
              job.status == .failed || job.status == .waitingToRetry else { return }
        job.status = .pending
        job.error = nil
        job.nextAttempt = nil
        job.attempt = 0
        try update(job)
        schedule()
    }

    func markDelivered(id: UUID) throws {
        guard var job = jobs.first(where: { $0.id == id }), job.status == .ready else { return }
        job.status = .delivered
        try update(job)
    }

    func setTranscript(id: UUID, text: String) throws {
        guard var job = jobs.first(where: { $0.id == id }), job.status == .ready else { return }
        job.transcript = text
        try update(job)
    }

    func delete(id: UUID) throws {
        guard let job = jobs.first(where: { $0.id == id }),
              ![.recording, .transcribing].contains(job.status) else { return }
        try fileManager.removeItem(at: directoryFor(id))
        jobs.removeAll { $0.id == id }
    }

    func export(id: UUID, to destination: URL) throws {
        let source = audioURL(id)
        let (rate, bytes) = try audioInfo(source)
        guard bytes > 0, bytes <= UInt64(UInt32.max) - 36 else {
            throw RecordingVaultError.invalidAudio
        }
        _ = fileManager.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: Self.wavHeader(rate: rate, byteCount: UInt32(bytes)))
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: RecordingWriter.headerSize)
        var remaining = bytes
        while remaining > 0 {
            let data = try input.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
            guard !data.isEmpty else { throw RecordingVaultError.invalidAudio }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
        try output.synchronize()
    }

    private func loadAndRecover() throws {
        let directories = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for directory in directories where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let manifest = directory.appendingPathComponent("job.json")
            do {
                var job = try JSONDecoder().decode(RecordingJob.self, from: Data(contentsOf: manifest))
                guard job.id == id else { throw RecordingVaultError.invalidAudio }
                if job.status == .recording || job.status == .transcribing {
                    if job.status == .recording {
                        job.captureWarning = "The app closed during recording. Only audio already written to disk survived."
                        job.expectedBytes = (try? audioInfo(audioURL(id)))?.1
                    }
                    job.status = .pending
                    job.error = nil
                    try save(job)
                }
                jobs.append(job)
            } catch {
                // Never remove a damaged manifest or its audio. Make it discoverable in Finder.
                let recovery = RecordingJob(id: id,
                    createdAt: Date(), status: .failed, language: "en", prompt: nil,
                    error: "Job metadata is damaged; audio remains in \(directory.path).")
                jobs.append(recovery)
            }
        }
        jobs.sort { $0.createdAt > $1.createdAt }
    }

    private func schedule() {
        wakeTimer?.cancel()
        wakeTimer = nil
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let job = self.jobs.first(where: { $0.status == .pending ||
                ($0.status == .waitingToRetry && ($0.nextAttempt ?? .distantPast) <= Date()) }) {
                await self.process(job.id)
            }
            self.worker = nil
            if let next = self.jobs.compactMap({ $0.status == .waitingToRetry ? $0.nextAttempt : nil }).min() {
                self.wakeTimer = Task { [weak self] in
                    let delay = max(0, next.timeIntervalSinceNow)
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.schedule()
                }
            }
        }
    }

    private func process(_ id: UUID) async {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        do {
            job.status = .transcribing
            try update(job)
            let source = audioURL(id)
            let (rate, totalBytes) = try audioInfo(source)
            guard totalBytes > 0 else { throw CloudflareTranscriptionError.emptyAudio }
            guard job.processedBytes <= totalBytes,
                  job.expectedBytes == nil || job.expectedBytes == totalBytes else {
                throw RecordingVaultError.invalidAudio
            }
            if job.expectedBytes == nil {
                job.expectedBytes = totalBytes
                try update(job)
            }
            let chunkSize = Self.chunkSeconds * UInt64(rate) * 2
            // Read credentials once per processing attempt, never once per chunk or to disk.
            let account = UserDefaults.standard.string(forKey: AppPreferenceKey.cloudflareAccountID) ?? ""
            let token = KeychainManager.getCloudflareAPIToken() ?? ""
            while job.processedBytes < totalBytes {
                let count = min(chunkSize, totalBytes - job.processedBytes)
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                try handle.seek(toOffset: RecordingWriter.headerSize + job.processedBytes)
                let pcm = try handle.read(upToCount: Int(count)) ?? Data()
                guard UInt64(pcm.count) == count else { throw RecordingVaultError.invalidAudio }
                let text = try await client.transcribe(
                    wavData: Self.wavHeader(rate: rate, byteCount: UInt32(count)) + pcm,
                    accountID: account, apiToken: token,
                    language: job.language, prompt: job.prompt
                )
                // Checkpoint the transcript and offset together, before the next network call.
                job.transcript += (job.transcript.isEmpty ? "" : " ") + text
                job.processedBytes += count
                job.attempt = 0
                try update(job)
            }
            guard !job.transcript.isEmpty else { throw CloudflareTranscriptionError.emptyTranscript }
            job.status = .ready
            job.error = nil
            job.nextAttempt = nil
            try update(job) // durable BEFORE any paste callback
            onReady?(id, job.transcript)
        } catch {
            let temporary = Self.isTemporary(error)
            job.status = temporary ? .waitingToRetry : .failed
            job.error = error.localizedDescription
            job.attempt += 1
            job.nextAttempt = temporary ? Date().addingTimeInterval(min(10 * pow(2, Double(min(job.attempt - 1, 8))), 1800)) : nil
            do { try update(job) }
            catch { storageError = "Cannot save recovery state: \(error.localizedDescription)" }
            onFailure?(id, job.error ?? "Transcription failed", temporary)
        }
    }

    private static func isTemporary(_ error: Error) -> Bool {
        if let cloud = error as? CloudflareTranscriptionError {
            if case .httpError(let status, _) = cloud {
                return status == 408 || status == 429 || (500...599).contains(status)
            }
            return false
        }
        if error is URLError { return true }
        return false
    }

    private func audioInfo(_ url: URL) throws -> (UInt32, UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        guard header.count == 16, String(data: header.prefix(8), encoding: .utf8) == "KAZEPCM1" else {
            throw RecordingVaultError.invalidAudio
        }
        let rate = header[8..<12].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        let size = try handle.seekToEnd()
        guard rate >= 8_000, rate <= 192_000, size >= RecordingWriter.headerSize else {
            throw RecordingVaultError.invalidAudio
        }
        return (rate, (size - RecordingWriter.headerSize) & ~UInt64(1))
    }

    private static func wavHeader(rate: UInt32, byteCount: UInt32) -> Data {
        var header = Data()
        func ascii(_ value: String) { header.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        ascii("RIFF"); u32(byteCount + 36); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        ascii("data"); u32(byteCount)
        return header
    }

    private func update(_ job: RecordingJob) throws {
        try save(job)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
    }

    private func save(_ job: RecordingJob) throws {
        let data = try JSONEncoder().encode(job)
        let destination = directoryFor(job.id).appendingPathComponent("job.json")
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func directoryFor(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func audioURL(_ id: UUID) -> URL { directoryFor(id).appendingPathComponent("audio.pcm") }
}
