import Foundation

// Offline stand-in: the test executable never reads the real Keychain.
enum KeychainManager {
    static func getCloudflareAPIToken() -> String? { "offline-test-token" }
}

final class MockCloudflare: URLProtocol {
    static let lock = NSLock()
    static var statuses = [Int]()
    static var payloadSizes = [Int]()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(contentsOf: buffer.prefix(read))
            }
        }
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let encoded = fields?["audio"] as? String ?? ""
        let wav = Data(base64Encoded: encoded) ?? Data()
        assert(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        assert(String(data: wav.dropFirst(8).prefix(4), encoding: .utf8) == "WAVE")
        assert(fields?["task"] as? String == "transcribe")
        assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-test-token")
        let (status, count): (Int, Int) = Self.lock.withLock {
            let status = Self.statuses.removeFirst()
            let count = Self.payloadSizes.count + 1
            Self.payloadSizes.append(body.count)
            return (status, count)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let json = status == 200 ? "{\"success\":true,\"result\":{\"text\":\"chunk \(count)\"}}"
                                 : "{\"success\":false,\"errors\":[{\"message\":\"temporary outage\"}]}"
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@main struct RecordingVaultTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaze-recovery-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockCloudflare.self]
        let client = CloudflareTranscriptionClient(session: URLSession(configuration: config))
        // CLI argument domain: no persisted app preferences or user credentials.
        assert(UserDefaults.standard.string(forKey: AppPreferenceKey.cloudflareAccountID) != nil)
        MockCloudflare.statuses = [200, 503, 503, 200, 200]
        var vault: RecordingVault? = RecordingVault(root: root, client: client)
        let (job, writer) = try vault!.begin(language: "en", prompt: nil)
        let second = [Float](repeating: 0.125, count: 16_000)
        for _ in 0..<61 { try writer.append(second, sampleRate: 16_000) }
        let audioURL = root.appendingPathComponent(job.id.uuidString + "/audio.pcm")
        let captured = try Data(contentsOf: audioURL)
        assert(captured.count == 16 + 61 * 16_000 * 2)
        try vault!.finish(id: job.id, writer: writer)
        try await until { vault?.jobs.first?.status == .waitingToRetry }
        assert(vault!.jobs.first!.processedBytes == 30 * 16_000 * 2)
        assert(vault!.jobs.first!.transcript == "chunk 1")
        // Simulate app relaunch after a transient outage: resume the remaining chunks.
        vault = nil
        vault = RecordingVault(root: root, client: client)
        assert(vault!.jobs.first!.processedBytes == 30 * 16_000 * 2)
        try vault!.retry(id: job.id)
        try await until { vault?.jobs.first?.status == .ready }
        assert(vault!.jobs.first!.transcript == "chunk 1 chunk 4 chunk 5")
        assert(MockCloudflare.payloadSizes.count == 5)
        let exported = root.appendingPathComponent("recovered.wav")
        try vault!.export(id: job.id, to: exported)
        let wav = try Data(contentsOf: exported)
        assert(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        assert(wav.count == 44 + 61 * 16_000 * 2)
        try vault!.markDelivered(id: job.id)
        assert(vault!.jobs.first!.status == .delivered)

        // Simulate a crash before stop; the prefix and interruption warning survive.
        let (interrupted, partial) = try vault!.begin(language: "en", prompt: nil)
        try partial.append(second, sampleRate: 16_000)
        try partial.close()
        vault = nil
        var restored = RecordingVault(root: root, client: client)
        let recovered = restored.jobs.first { $0.id == interrupted.id }!
        assert(recovered.status == .pending && recovered.captureWarning != nil)
        // Park this interrupted job so the next tests control exactly which mock request runs.
        let manifest = root.appendingPathComponent(interrupted.id.uuidString + "/job.json")
        var parked = recovered
        parked.status = .failed
        try JSONEncoder().encode(parked).write(to: manifest, options: .atomic)
        restored = RecordingVault(root: root, client: client)

        // A permanent authorization error must not silently loop; manual Retry works.
        MockCloudflare.statuses = [401, 200]
        let (denied, deniedWriter) = try restored.begin(language: "en", prompt: nil)
        try deniedWriter.append(second, sampleRate: 16_000)
        try restored.finish(id: denied.id, writer: deniedWriter)
        try await until { restored.jobs.first(where: { $0.id == denied.id })?.status == .failed }
        try restored.retry(id: denied.id)
        try await until { restored.jobs.first(where: { $0.id == denied.id })?.status == .ready }

        // A temporary outage is retried automatically, without UI interaction.
        MockCloudflare.statuses = [503, 503, 200]
        let (offline, offlineWriter) = try restored.begin(language: "en", prompt: nil)
        try offlineWriter.append(second, sampleRate: 16_000)
        try restored.finish(id: offline.id, writer: offlineWriter)
        try await until { restored.jobs.first(where: { $0.id == offline.id })?.status == .waitingToRetry }
        restored = RecordingVault(root: root, client: client)
        restored.startRecovery()
        try await until { restored.jobs.first(where: { $0.id == offline.id })?.status == .ready }

        // Corrupt metadata must not result in silent audio deletion.
        try Data("broken manifest".utf8).write(to: manifest)
        let damaged = RecordingVault(root: root, client: client)
        assert(damaged.jobs.first(where: { $0.id == interrupted.id })?.status == .failed)
        let rescued = root.appendingPathComponent("damaged-metadata.wav")
        try damaged.export(id: interrupted.id, to: rescued)
        let rescuedData = try Data(contentsOf: rescued)
        assert(rescuedData.count > 44)

        // A truncated file can never become a misleading "ready" transcript.
        let originalManifest = root.appendingPathComponent(job.id.uuidString + "/job.json")
        var truncated = damaged.jobs.first { $0.id == job.id }!
        truncated.status = .pending
        try JSONEncoder().encode(truncated).write(to: originalManifest, options: .atomic)
        let originalAudio = try FileHandle(forWritingTo: audioURL)
        try originalAudio.truncate(atOffset: 16 + 2_000)
        try originalAudio.close()
        let checked = RecordingVault(root: root, client: client)
        checked.startRecovery()
        try await until { checked.jobs.first(where: { $0.id == job.id })?.status == .failed }
        print("PASS: disk capture, chunk checkpoint, retry after relaunch, auto retry, manual retry, export, and interrupted/corrupt recovery")
    }

    private static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        fatalError("Timed out waiting for offline recovery state")
    }
}
