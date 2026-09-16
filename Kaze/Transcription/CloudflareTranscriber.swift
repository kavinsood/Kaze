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

    private let client: CloudflareTranscriptionClient
    private let microphoneCapture = MicrophoneCaptureSession()
    private let bufferQueue = DispatchQueue(label: "com.kaze.cloudflare.audioBuffer")
    private var audioBuffer: [Float] = []
    private var inputSampleRate: Double = 16_000
    private var durationLimitStopScheduled = false
    private var transcriptionTask: Task<Void, Never>?
    private var sessionConfiguration: SessionConfiguration?

    nonisolated private static let targetSampleRate: Double = 16_000
    private static let maxRecordingSeconds: Double = 300
    private static let initialBufferCapacity = 48_000 * 60

    private struct SessionConfiguration {
        let accountID: String
        let apiToken: String
        let language: String
        let prompt: String?
    }

    init(client: CloudflareTranscriptionClient = .init()) {
        self.client = client
    }

    deinit {
        transcriptionTask?.cancel()
        let capture = microphoneCapture
        Task { @MainActor in capture.stop() }
    }

    func requestPermissions() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startRecording() {
        guard !isRecording else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil

        let accountID = UserDefaults.standard.string(forKey: AppPreferenceKey.cloudflareAccountID) ?? ""
        let apiToken = KeychainManager.getCloudflareAPIToken() ?? ""
        let language = UserDefaults.standard.string(forKey: AppPreferenceKey.transcriptionLanguage) ?? "en"
        sessionConfiguration = SessionConfiguration(
            accountID: accountID,
            apiToken: apiToken,
            language: language,
            prompt: Self.transcriptionPrompt(customWords: customWords)
        )

        bufferQueue.sync {
            audioBuffer = []
            audioBuffer.reserveCapacity(Self.initialBufferCapacity)
            durationLimitStopScheduled = false
        }
        transcribedText = ""
        audioLevel = 0

        microphoneCapture.stop()
        microphoneCapture.onAudioChunk = { [weak self] chunk in
            guard let self else { return }

            let maxSamples = Int(chunk.sampleRate * Self.maxRecordingSeconds)
            let shouldStopAtDurationLimit: Bool = self.bufferQueue.sync {
                self.inputSampleRate = chunk.sampleRate
                if self.audioBuffer.count < maxSamples {
                    let remaining = maxSamples - self.audioBuffer.count
                    self.audioBuffer.append(contentsOf: chunk.monoSamples.prefix(remaining))
                }
                if self.audioBuffer.count >= maxSamples && !self.durationLimitStopScheduled {
                    self.durationLimitStopScheduled = true
                    return true
                }
                return false
            }

            let level = Self.normalizedAudioLevel(from: chunk.monoSamples)
            Task { @MainActor [weak self] in
                self?.audioLevel = level
                if shouldStopAtDurationLimit, self?.isRecording == true {
                    self?.stopRecording()
                }
            }
        }

        do {
            try microphoneCapture.start(deviceUID: selectedDeviceUID)
            isRecording = true
        } catch {
            microphoneCapture.stop()
            isRecording = false
            sessionConfiguration = nil
            onTranscriptionFailed?("Could not start microphone recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        microphoneCapture.stop()
        isRecording = false

        let captured: ([Float], Double) = bufferQueue.sync {
            let result = (audioBuffer, inputSampleRate)
            audioBuffer = []
            return result
        }

        guard !captured.0.isEmpty else {
            sessionConfiguration = nil
            onTranscriptionFailed?(CloudflareTranscriptionError.emptyAudio.localizedDescription)
            return
        }

        guard let configuration = sessionConfiguration else {
            onTranscriptionFailed?(CloudflareTranscriptionError.missingAPIToken.localizedDescription)
            return
        }
        sessionConfiguration = nil

        transcriptionTask?.cancel()
        isEnhancing = true
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let wavData = try await Task.detached(priority: .userInitiated) {
                    try Self.makeWAVData(samples: captured.0, inputSampleRate: captured.1)
                }.value
                try Task.checkCancellation()

                let text = try await client.transcribe(
                    wavData: wavData,
                    accountID: configuration.accountID,
                    apiToken: configuration.apiToken,
                    language: configuration.language,
                    prompt: configuration.prompt
                )
                try Task.checkCancellation()

                transcribedText = text
                isEnhancing = false
                onTranscriptionFinished?(text)
            } catch is CancellationError {
                isEnhancing = false
                return
            } catch {
                isEnhancing = false
                onTranscriptionFailed?(error.localizedDescription)
            }
        }
    }

    private nonisolated static func transcriptionPrompt(customWords: [String]) -> String? {
        guard !customWords.isEmpty else { return nil }
        return "Vocabulary: \(customWords.joined(separator: ", "))."
    }

    private nonisolated static func makeWAVData(
        samples: [Float],
        inputSampleRate: Double
    ) throws -> Data {
        guard !samples.isEmpty else {
            throw CloudflareTranscriptionError.emptyAudio
        }

        let resampled: [Float]
        if abs(inputSampleRate - targetSampleRate) > 1 {
            let ratio = targetSampleRate / inputSampleRate
            let outputLength = Int(Double(samples.count) * ratio)
            guard outputLength > 0 else {
                throw CloudflareTranscriptionError.emptyAudio
            }
            var output = [Float](repeating: 0, count: outputLength)
            var control = (0..<outputLength).map { Float(Double($0) / ratio) }
            vDSP_vlint(
                samples,
                &control,
                1,
                &output,
                1,
                vDSP_Length(outputLength),
                vDSP_Length(samples.count)
            )
            resampled = output
        } else {
            resampled = samples
        }

        var pcm = [Int16]()
        pcm.reserveCapacity(resampled.count)
        for sample in resampled {
            let clamped = min(max(sample, -1), 1)
            pcm.append(Int16(clamped * Float(Int16.max)).littleEndian)
        }

        let dataByteCount = pcm.count * MemoryLayout<Int16>.size
        guard dataByteCount <= Int(UInt32.max) else {
            throw CloudflareTranscriptionError.emptyAudio
        }

        var wav = Data(capacity: 44 + dataByteCount)
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(UInt32(36 + dataByteCount))
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(targetSampleRate))
        wav.appendLittleEndian(UInt32(targetSampleRate * 2))
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.appendASCII("data")
        wav.appendLittleEndian(UInt32(dataByteCount))
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }

    private nonisolated static func normalizedAudioLevel(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return min(sqrt(meanSquare) * 20, 1)
    }
}

private nonisolated extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
