import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit
import os

/// Screenshots and screen recordings, CleanShot style: pick an area or
/// window, save to the capture folder, then show it in the side previews.
@MainActor
@Observable
final class ScreenCapture {
    private(set) var isRecording = false

    @ObservationIgnored private let log = Logger(subsystem: "com.giovani.MacUtility", category: "capture")
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let selector = CaptureSelector()
    @ObservationIgnored private let previews = QuickAccessOverlay()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var recording: ScreenRecording?
    @ObservationIgnored private var camera: CameraBubble?
    @ObservationIgnored private var keystrokes: KeystrokeOverlay?
    @ObservationIgnored private var control: RecordingControl?

    init(permissions: Permissions) {
        self.permissions = permissions
    }

    func captureArea() {
        run { [self] in
            guard let target = await selector.select(.screenshot) else { return }
            try await screenshot(target)
        }
    }

    func captureScreen() {
        run { [self] in
            guard let id = NSScreen.underMouse?.displayID else { return }
            try await screenshot(.display(id))
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            run { [self] in
                guard let target = await selector.select(.recording) else { return }
                try await startRecording(target)
            }
        }
    }

    /// Runs one capture flow at a time, after checking Screen Recording.
    private func run(_ flow: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        permissions.refresh()
        guard permissions.screenRecording else {
            permissions.requestScreenRecording()
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await flow()
            } catch {
                log.error("capture failed: \(error.localizedDescription)")
                HUD.show(error.localizedDescription)
            }
        }
    }

    // MARK: Screenshots

    private func screenshot(_ target: CaptureTarget) async throws {
        previews.setHidden(true)
        defer { previews.setHidden(false) }
        // Give the selection overlay a frame to leave the screen.
        try await Task.sleep(for: .milliseconds(80))

        let content = try await CaptureContent.make(for: target)
        let config = SCStreamConfiguration()
        config.width = content.pixelWidth
        config.height = content.pixelHeight
        if let sourceRect = content.sourceRect { config.sourceRect = sourceRect }
        config.showsCursor = false
        if case .window = target { config.ignoreShadowsSingleWindow = false }

        let image = try await SCScreenshotManager.captureImage(contentFilter: content.filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        // Keep the point size so Retina captures open at their real size.
        rep.size = NSSize(width: CGFloat(image.width) / content.scale, height: CGFloat(image.height) / content.scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CaptureError.nothingCaptured }

        let url = CaptureFiles.newURL(prefix: "Screenshot", ext: "png")
        try png.write(to: url, options: .atomic)
        NSSound(named: "Grab")?.play()
        log.info("screenshot saved: \(url.lastPathComponent)")
        previews.show(CaptureResult(kind: .screenshot, url: url, thumbnail: NSImage(cgImage: image, size: .zero)))
    }

    // MARK: Recording

    private func startRecording(_ target: CaptureTarget) async throws {
        let wantsCamera = RecordingOptions.camera
        let wantsMic = RecordingOptions.microphone
        if wantsCamera, !(await AVCaptureDevice.requestAccess(for: .video)) {
            HUD.show("Camera access is off in System Settings")
        }
        if wantsMic, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            HUD.show("Microphone access is off in System Settings")
        }
        let cameraAllowed = wantsCamera && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let micAllowed = wantsMic && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        let area = target.rect
        let control = RecordingControl { [weak self] in
            Task { await self?.stopRecording() }
        }
        control.show(on: target.screen ?? NSScreen.underMouse ?? NSScreen.screens[0])
        self.control = control

        if cameraAllowed, let camera = CameraBubble() {
            camera.show(in: area)
            self.camera = camera
        }
        if RecordingOptions.keystrokes {
            permissions.refresh()
            if permissions.inputMonitoring {
                let overlay = KeystrokeOverlay()
                if overlay.start(in: area) { keystrokes = overlay }
            } else {
                permissions.requestInputMonitoring()
            }
        }
        // Let the accessory windows reach the window server before the
        // shareable content snapshot, so the control bar can be excluded.
        try await Task.sleep(for: .milliseconds(150))

        do {
            let content = try await CaptureContent.make(for: target, excluding: [control.windowID])
            let url = CaptureFiles.newURL(prefix: "Recording", ext: "mp4")
            let recording = try ScreenRecording(content: content, microphone: micAllowed, url: url)
            try await recording.start()
            self.recording = recording
            isRecording = true
            log.info("recording started")
        } catch {
            tearDownAccessories()
            throw error
        }
    }

    private func stopRecording() async {
        guard let recording else { return }
        self.recording = nil
        isRecording = false
        tearDownAccessories()
        let ok = await recording.stop()
        guard ok else {
            HUD.show("Recording failed")
            return
        }
        log.info("recording saved: \(recording.url.lastPathComponent)")
        let thumbnail = await Thumbnails.forVideo(recording.url) ?? NSWorkspace.shared.icon(forFile: recording.url.path)
        previews.show(CaptureResult(kind: .recording, url: recording.url, thumbnail: thumbnail))
    }

    private func tearDownAccessories() {
        control?.hide()
        camera?.hide()
        keystrokes?.stop()
        control = nil
        camera = nil
        keystrokes = nil
    }
}
