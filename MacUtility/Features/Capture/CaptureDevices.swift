import AVFoundation

/// A camera or microphone as the recording bar lists it.
struct DeviceChoice: Identifiable, Hashable {
    let id: String
    let name: String

    init(_ device: AVCaptureDevice) {
        id = device.uniqueID
        name = device.localizedName
    }
}

/// Cameras and microphones for recordings. The chosen one is remembered by
/// unique ID; none chosen, or one that's unplugged, means the system default.
enum CaptureDevices {
    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.filter(\.isConnected)
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.filter(\.isConnected)
    }

    static func camera() -> AVCaptureDevice? {
        if let id = RecordingOptions.cameraID, let device = AVCaptureDevice(uniqueID: id), device.isConnected {
            return device
        }
        return AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
    }

    static func microphone() -> AVCaptureDevice? {
        if let id = RecordingOptions.microphoneID, let device = AVCaptureDevice(uniqueID: id), device.isConnected {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }
}

/// Input level of a microphone, for the meter on the recording bar, so you
/// can tell the right one is picked before you start.
final class MicLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.giovani.MacUtility.mic-level")

    init?(device: AVCaptureDevice) {
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        super.init()
        // Levels are only measured while samples flow to someone.
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() { queue.async { [self] in session.startRunning() } }
    func stop() { queue.async { [self] in session.stopRunning() } }

    var level: Float { Self.level(of: output) }

    /// Loudest channel's average power, from -50 dB (0) to 0 dB (1).
    static func level(of output: AVCaptureAudioDataOutput) -> Float {
        let channels = output.connections.first?.audioChannels ?? []
        guard let power = channels.map(\.averagePowerLevel).max() else { return 0 }
        return max(0, min(1, (power + 50) / 50))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
