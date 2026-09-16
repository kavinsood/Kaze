import Foundation
import Combine
import AVFoundation

struct AudioInputDevice: Equatable {
    let uid: String
    let name: String
}

/// Shared observable surface for the Cloudflare transcriber and recording overlay.
@MainActor
protocol TranscriberProtocol: ObservableObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var transcribedText: String { get }
    var isEnhancing: Bool { get set }

    /// The AVCapture device unique ID to use for recording, or `nil` for the current default input.
    var selectedDeviceUID: String? { get set }

    var onTranscriptionFinished: ((String) -> Void)? { get set }

    func requestPermissions() async -> Bool
    func startRecording()
    func stopRecording()
}

func listAudioInputDevices() -> [AudioInputDevice] {
    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    )

    return discoverySession.devices
        .map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func isKnownAudioInputDevice(_ uid: String) -> Bool {
    listAudioInputDevices().contains(where: { $0.uid == uid })
}
