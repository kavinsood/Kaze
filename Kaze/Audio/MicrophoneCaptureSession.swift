import Foundation
import AVFoundation
import Accelerate
import CoreMedia

enum MicrophoneCaptureError: LocalizedError {
    case deviceUnavailable
    case inputCreationFailed
    case outputCreationFailed
    case unsupportedAudioFormat
    case discontinuity

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "The selected microphone is unavailable."
        case .inputCreationFailed:
            return "Kaze could not create a capture input for the selected microphone."
        case .outputCreationFailed: 
            return "Kaze could not create a capture output for the selected microphone."
        case .unsupportedAudioFormat:
            return "Kaze received an unsupported audio format from the microphone."
        case .discontinuity:
            return "The microphone dropped audio; the saved recording may contain a gap."
        }
    }
}

final class MicrophoneCaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    struct CapturedAudioChunk {
        let sampleBuffer: CMSampleBuffer
        let monoSamples: [Float]
        let sampleRate: Double
    }

    var onAudioChunk: ((CapturedAudioChunk) -> Void)?
    var onCaptureError: ((Error) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.kaze.capture.session")
    private let sampleBufferQueue = DispatchQueue(label: "com.kaze.capture.samples")

    private var captureSession = AVCaptureSession()
    private var audioOutput = AVCaptureAudioDataOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var observers: [NSObjectProtocol] = []
    // Only accessed from sampleBufferQueue.
    private var expectedNextTimestamp: Double?

    func start(deviceUID: String?) throws {
        var thrownError: Error?
        sampleBufferQueue.sync { expectedNextTimestamp = nil }

        sessionQueue.sync {
            do {
                try configureSession(deviceUID: deviceUID)
                observeCaptureFailures()
                captureSession.startRunning()
                if !captureSession.isRunning { throw MicrophoneCaptureError.deviceUnavailable }
            } catch {
                removeObservers()
                thrownError = error
            }
        }

        if let thrownError {
            throw thrownError
        }
    }

    func stop() {
        sessionQueue.sync {
            removeObservers()
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            if captureSession.isRunning {
                captureSession.stopRunning()
            }

            captureSession.beginConfiguration()
            if let deviceInput {
                captureSession.removeInput(deviceInput)
                self.deviceInput = nil
            }
            captureSession.removeOutput(audioOutput)
            captureSession.commitConfiguration()

            audioOutput = AVCaptureAudioDataOutput()
        }

        // Ensure no captured buffers are still waiting to be delivered before callers
        // close their transcription input stream.
        sampleBufferQueue.sync {}
        expectedNextTimestamp = nil
    }

    private func observeCaptureFailures() {
        removeObservers()
        for name in [AVCaptureSession.runtimeErrorNotification,
                     AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: captureSession, queue: nil
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                    ?? NSError(domain: "KazeCapture", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The microphone capture session was interrupted."
                    ])
                self?.onCaptureError?(error)
            })
        }
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func configureSession(deviceUID: String?) throws {
        let device: AVCaptureDevice?
        if let deviceUID, !deviceUID.isEmpty {
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices
            device = devices.first(where: { $0.uniqueID == deviceUID })
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let device else {
            throw MicrophoneCaptureError.deviceUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicrophoneCaptureError.inputCreationFailed
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleBufferQueue)

        captureSession.beginConfiguration()

        if let existingInput = deviceInput {
            captureSession.removeInput(existingInput)
            deviceInput = nil
        }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw MicrophoneCaptureError.inputCreationFailed
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(output) else {
            captureSession.removeInput(input)
            captureSession.commitConfiguration()
            throw MicrophoneCaptureError.outputCreationFailed
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()

        deviceInput = input
        audioOutput = output
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        do {
            let (monoSamples, sampleRate) = try extractMonoSamples(from: sampleBuffer)
            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let hasGap = timestamp.isFinite && expectedNextTimestamp.map {
                abs(timestamp - $0) > 0.2
            } == true
            expectedNextTimestamp = timestamp.isFinite
                ? timestamp + Double(monoSamples.count) / sampleRate : nil
            onAudioChunk?(CapturedAudioChunk(sampleBuffer: sampleBuffer, monoSamples: monoSamples, sampleRate: sampleRate))
            if hasGap { onCaptureError?(MicrophoneCaptureError.discontinuity) }
        } catch {
            onCaptureError?(error)
        }
    }

    /// Scratch buffer reused across callbacks to avoid per-callback allocation.
    /// Only accessed from the `sampleBufferQueue` serial queue, so no lock needed.
    private var scratchBuffer: [Float] = []

    private func extractMonoSamples(from sampleBuffer: CMSampleBuffer) throws -> ([Float], Double) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw MicrophoneCaptureError.unsupportedAudioFormat
        }

        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw MicrophoneCaptureError.unsupportedAudioFormat
        }

        var blockBuffer: CMBlockBuffer?
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size + (Int(asbd.mChannelsPerFrame) - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: audioBufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }

        let audioBufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            throw MicrophoneCaptureError.unsupportedAudioFormat
        }

        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        // Reuse scratch buffer to avoid per-callback allocation
        if scratchBuffer.count < frameCount {
            scratchBuffer = [Float](repeating: 0, count: frameCount)
        }
        let n = vDSP_Length(frameCount)

        // Zero out the working region
        var zero: Float = 0
        vDSP_vfill(&zero, &scratchBuffer, 1, n)

        let bufferListPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        if isFloat && asbd.mBitsPerChannel == 32 {
            if isNonInterleaved {
                // Each channel is a separate buffer; sum with vDSP_vadd
                for channel in 0..<min(channelCount, bufferListPointer.count) {
                    guard let data = bufferListPointer[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    vDSP_vadd(scratchBuffer, 1, data, 1, &scratchBuffer, 1, n)
                }
            } else {
                guard let data = bufferListPointer.first?.mData?.assumingMemoryBound(to: Float.self) else {
                    throw MicrophoneCaptureError.unsupportedAudioFormat
                }
                if channelCount == 1 {
                    // Mono: direct copy
                    memcpy(&scratchBuffer, data, frameCount * MemoryLayout<Float>.size)
                } else {
                    // Interleaved multi-channel: sum channels with strided adds
                    for channel in 0..<channelCount {
                        vDSP_vadd(scratchBuffer, 1, data.advanced(by: channel), vDSP_Stride(channelCount), &scratchBuffer, 1, n)
                    }
                }
            }
        } else if isSignedInteger && asbd.mBitsPerChannel == 16 {
            // Convert Int16 to Float using vDSP, then accumulate
            var conversionBuffer = [Float](repeating: 0, count: frameCount)
            if isNonInterleaved {
                for channel in 0..<min(channelCount, bufferListPointer.count) {
                    guard let data = bufferListPointer[channel].mData?.assumingMemoryBound(to: Int16.self) else { continue }
                    vDSP_vflt16(data, 1, &conversionBuffer, 1, n)
                    vDSP_vadd(scratchBuffer, 1, conversionBuffer, 1, &scratchBuffer, 1, n)
                }
            } else {
                guard let data = bufferListPointer.first?.mData?.assumingMemoryBound(to: Int16.self) else {
                    throw MicrophoneCaptureError.unsupportedAudioFormat
                }
                for channel in 0..<channelCount {
                    vDSP_vflt16(data.advanced(by: channel), vDSP_Stride(channelCount), &conversionBuffer, 1, n)
                    vDSP_vadd(scratchBuffer, 1, conversionBuffer, 1, &scratchBuffer, 1, n)
                }
            }
            // Scale by 1/Int16.max
            var scale = Float(1.0) / Float(Int16.max)
            vDSP_vsmul(scratchBuffer, 1, &scale, &scratchBuffer, 1, n)
        } else if isSignedInteger && asbd.mBitsPerChannel == 32 {
            // Convert Int32 to Float using vDSP, then accumulate
            var conversionBuffer = [Float](repeating: 0, count: frameCount)
            if isNonInterleaved {
                for channel in 0..<min(channelCount, bufferListPointer.count) {
                    guard let data = bufferListPointer[channel].mData?.assumingMemoryBound(to: Int32.self) else { continue }
                    vDSP_vflt32(data, 1, &conversionBuffer, 1, n)
                    vDSP_vadd(scratchBuffer, 1, conversionBuffer, 1, &scratchBuffer, 1, n)
                }
            } else {
                guard let data = bufferListPointer.first?.mData?.assumingMemoryBound(to: Int32.self) else {
                    throw MicrophoneCaptureError.unsupportedAudioFormat
                }
                for channel in 0..<channelCount {
                    vDSP_vflt32(data.advanced(by: channel), vDSP_Stride(channelCount), &conversionBuffer, 1, n)
                    vDSP_vadd(scratchBuffer, 1, conversionBuffer, 1, &scratchBuffer, 1, n)
                }
            }
            // Scale by 1/Int32.max
            var scale = Float(1.0) / Float(Int32.max)
            vDSP_vsmul(scratchBuffer, 1, &scale, &scratchBuffer, 1, n)
        } else {
            throw MicrophoneCaptureError.unsupportedAudioFormat
        }

        // Average across channels
        if channelCount > 1 {
            var divisor = Float(channelCount)
            vDSP_vsdiv(scratchBuffer, 1, &divisor, &scratchBuffer, 1, n)
        }

        // Return a copy of just the valid region
        let monoSamples = Array(scratchBuffer.prefix(frameCount))
        return (monoSamples, asbd.mSampleRate)
    }
}
