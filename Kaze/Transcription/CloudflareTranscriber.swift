import Accelerate
import AVFoundation
import Combine
import Foundation

enum CloudflareTranscriptionError: LocalizedError {
    case missingAccountID
    case invalidAccountID
    case missingAPIToken
    case emptyAudio
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case apiError(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingAccountID:
            return "Add your Cloudflare Account ID in Settings."
        case .invalidAccountID:
            return "The Cloudflare Account ID must be a 32-character hexadecimal value."
        case .missingAPIToken:
            return "Add a Cloudflare API token in Settings."
        case .emptyAudio:
            return "No audio was captured."
        case .invalidResponse:
            return "Cloudflare returned an invalid response."
        case .httpError(let statusCode, let message):
            return message.isEmpty
                ? "Cloudflare returned HTTP \(statusCode)."
                : "Cloudflare returned HTTP \(statusCode): \(message)"
        case .apiError(let message):
            return "Cloudflare could not transcribe the recording: \(message)"
        case .emptyTranscript:
            return "Cloudflare returned an empty transcription."
        }
    }
}

/// Calls Cloudflare's native Workers AI endpoint.
/// The only model this client permits is Cloudflare-hosted Whisper Large V3 Turbo.
nonisolated struct CloudflareTranscriptionClient: Sendable {
    static let modelID = "@cf/openai/whisper-large-v3-turbo"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        wavData: Data,
        accountID: String,
        apiToken: String,
        language: String?,
        prompt: String?
    ) async throws -> String {
        let normalizedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccountID.isEmpty else {
            throw CloudflareTranscriptionError.missingAccountID
        }
        guard normalizedAccountID.range(
            of: "^[A-Fa-f0-9]{32}$",
            options: .regularExpression
        ) != nil else {
            throw CloudflareTranscriptionError.invalidAccountID
        }

        let normalizedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw CloudflareTranscriptionError.missingAPIToken
        }
        guard !wavData.isEmpty else {
            throw CloudflareTranscriptionError.emptyAudio
        }

        let urlString = "https://api.cloudflare.com/client/v4/accounts/\(normalizedAccountID)/ai/run/\(Self.modelID)"
        guard let url = URL(string: urlString) else {
            throw CloudflareTranscriptionError.invalidAccountID
        }

        let normalizedLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPrompt = prompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let body = WhisperRequest(
            audio: wavData.base64EncodedString(),
            task: "transcribe",
            language: normalizedLanguage?.isEmpty == false ? normalizedLanguage : nil,
            vadFilter: true,
            initialPrompt: normalizedPrompt?.isEmpty == false ? normalizedPrompt : nil,
            conditionOnPreviousText: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(normalizedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        let (data, response) = try await performWithOneRetry(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareTranscriptionError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(RunResponse.self, from: data)
            let message = errorResponse?.bestErrorMessage
                ?? String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            throw CloudflareTranscriptionError.httpError(
                statusCode: httpResponse.statusCode,
                message: String(message.prefix(500))
            )
        }

        let decoded: RunResponse
        do {
            decoded = try JSONDecoder().decode(RunResponse.self, from: data)
        } catch {
            throw CloudflareTranscriptionError.invalidResponse
        }

        if let message = decoded.bestErrorMessage {
            throw CloudflareTranscriptionError.apiError(message)
        }

        let text = decoded.result?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw CloudflareTranscriptionError.emptyTranscript
        }
        return text
    }

    private func performWithOneRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastResult: (Data, URLResponse)?

        for attempt in 0...1 {
            do {
                let result = try await session.data(for: request)
                lastResult = result

                guard attempt == 0,
                      let response = result.1 as? HTTPURLResponse,
                      response.statusCode == 408
                        || response.statusCode == 429
                        || (500...599).contains(response.statusCode) else {
                    return result
                }

                let retryDelay = min(
                    Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1,
                    5
                )
                try await Task.sleep(for: .seconds(max(retryDelay, 0.25)))
            } catch let error as URLError where attempt == 0 && Self.isRetryable(error) {
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        guard let lastResult else {
            throw CloudflareTranscriptionError.invalidResponse
        }
        return lastResult
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private struct WhisperRequest: Encodable {
        let audio: String
        let task: String
        let language: String?
        let vadFilter: Bool
        let initialPrompt: String?
        let conditionOnPreviousText: Bool

        private enum CodingKeys: String, CodingKey {
            case audio
            case task
            case language
            case vadFilter = "vad_filter"
            case initialPrompt = "initial_prompt"
            case conditionOnPreviousText = "condition_on_previous_text"
        }
    }

    private struct RunResponse: Decodable {
        let result: Result?
        let state: String?
        let success: Bool?
        let errors: [APIMessage]?
        let messages: [APIMessage]?

        struct Result: Decodable {
            let text: String?
        }

        struct APIMessage: Decodable {
            let code: Int?
            let message: String?
        }

        var bestErrorMessage: String? {
            if let message = errors?.compactMap(\.message).first, !message.isEmpty {
                return message
            }
            if success == false {
                return messages?.compactMap(\.message).first ?? "The request was not successful."
            }
            if let state, state.localizedCaseInsensitiveCompare("completed") != .orderedSame {
                return messages?.compactMap(\.message).first ?? "Request state: \(state)"
            }
            return nil
        }
    }
}

/// Records microphone audio and submits it to Whisper Large V3 Turbo after the hotkey is released.
@MainActor
final class CloudflareTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    var selectedDeviceUID: String?
    var customWords: [String] = []
    var onTranscriptionFinished: ((String) -> Void)?
    var onTranscriptionFailed: ((String) -> Void)?
    var onRecordingStopped: (() -> Void)?

    private let vault: RecordingVault
    private let microphoneCapture = MicrophoneCaptureSession()
    private var writer: RecordingWriter?
    private(set) var jobID: UUID?
    private let captureIssueLock = NSLock()
    private var captureFailureScheduled = false
    private var captureIssue: String?

    init(vault: RecordingVault) {
        self.vault = vault
    }

    deinit {
        let capture = microphoneCapture
        Task { @MainActor in capture.stop() }
    }

    func requestPermissions() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startRecording() {
        guard !isRecording else { return }
        let language = UserDefaults.standard.string(forKey: AppPreferenceKey.transcriptionLanguage) ?? "en"
        do {
            let (job, newWriter) = try vault.begin(language: language,
                prompt: Self.transcriptionPrompt(customWords: customWords))
            jobID = job.id
            writer = newWriter
        } catch {
            onTranscriptionFailed?("Could not create a local recording: \(error.localizedDescription)")
            return
        }
        transcribedText = ""
        audioLevel = 0
        isEnhancing = false
        captureIssueLock.withLock {
            captureFailureScheduled = false
            captureIssue = nil
        }

        microphoneCapture.stop()
        microphoneCapture.onAudioChunk = { [weak self] chunk in
            guard let self else { return }
            do {
                try self.writer?.append(chunk.monoSamples, sampleRate: chunk.sampleRate)
            } catch {
                self.captureDidFail(error)
                return
            }
            let level = Self.normalizedAudioLevel(from: chunk.monoSamples)
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
        microphoneCapture.onCaptureError = { [weak self] error in self?.captureDidFail(error) }

        do {
            try microphoneCapture.start(deviceUID: selectedDeviceUID)
            isRecording = true
        } catch {
            microphoneCapture.stop()
            isRecording = false
            if let id = jobID, let writer {
                try? vault.finish(id: id, writer: writer, warning: error.localizedDescription)
            }
            writer = nil
            jobID = nil
            onTranscriptionFailed?("Could not start microphone recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        microphoneCapture.stop()
        isRecording = false
        guard let id = jobID, let writer else { return }
        self.writer = nil
        let issue = captureIssueLock.withLock { captureIssue }
        isEnhancing = issue == nil
        do {
            try vault.finish(id: id, writer: writer, warning: issue)
            if let issue {
                onTranscriptionFailed?("Recording stopped: \(issue). The captured portion is in Settings → Recordings.")
            } else {
                onRecordingStopped?()
            }
        } catch {
            isEnhancing = false
            onTranscriptionFailed?("Could not finalize local recording: \(error.localizedDescription). Check Recordings in Settings.")
        }
    }

    private func captureDidFail(_ error: Error) {
        let shouldStop = captureIssueLock.withLock { () -> Bool in
            guard !captureFailureScheduled else { return false }
            captureFailureScheduled = true
            captureIssue = error.localizedDescription
            return true
        }
        guard shouldStop else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }
            self.stopRecording()
        }
    }

    private nonisolated static func transcriptionPrompt(customWords: [String]) -> String? {
        guard !customWords.isEmpty else { return nil }
        return "Vocabulary: \(customWords.joined(separator: ", "))."
    }

    private nonisolated static func normalizedAudioLevel(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return min(sqrt(meanSquare) * 20, 1)
    }
}
