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
    private(set) var isPaused = false

    @ObservationIgnored private let log = Logger(subsystem: "com.giovani.MacUtility", category: "capture")
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let selector = CaptureSelector()
    @ObservationIgnored private let previews = QuickAccessOverlay()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var recording: ScreenRecording?
    @ObservationIgnored private var camera: CameraBubble?
    @ObservationIgnored private var keystrokes: KeystrokeOverlay?
    @ObservationIgnored private var micMonitor: MicLevelMonitor?
    /// The bar is up and Record hasn't been pressed yet.
    @ObservationIgnored private var waitingForRecord = false
    @ObservationIgnored private var control: RecordingControl?
    @ObservationIgnored private var recordArea = CGRect.zero
    /// Waiting for Record or Cancel on the bar.
    @ObservationIgnored private var pendingStart: CheckedContinuation<Bool, Never>?

    init(permissions: Permissions) {
        self.permissions = permissions
        CaptureFiles.clearPending()
    }

    #if DEBUG
    /// Launch with `-testPreview <file>` to show a preview without capturing.
    func showTestPreview(_ url: URL) {
        let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        previews.show(CaptureResult(kind: .screenshot, url: url, thumbnail: image))
    }

    func openTestEditor(_ url: URL) { previews.openEditor(url) }
    #endif

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
        } else if let pendingStart {
            self.pendingStart = nil
            pendingStart.resume(returning: true)
        } else {
            run { [self] in
                guard let target = await selector.select(.recording) else { return }
                try await startRecording(target)
            }
        }
    }

    /// Runs one capture flow at a time, after checking Screen Recording.
    /// Earlier captures' previews hide while you pick and capture, and come
    /// back with the new one; a recording keeps them hidden until it stops.
    private func run(_ flow: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        permissions.refresh()
        guard permissions.screenRecording else {
            permissions.requestScreenRecording()
            return
        }
        busy = true
        previews.setHidden(true)
        Task {
            defer {
                busy = false
                if !isRecording { previews.setHidden(false) }
            }
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
        // Give the selection overlay a frame to leave the screen.
        try await Task.sleep(for: .milliseconds(80))

        let content = try await CaptureContent.make(for: target, excluding: [previews.windowID])
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
        previews.show(CaptureResult(kind: .screenshot, url: url, thumbnail: NSImage(cgImage: image, size: rep.size)))
    }

    // MARK: Recording

    private func startRecording(_ target: CaptureTarget) async throws {
        recordArea = target.rect
        let control = RecordingControl { [weak self] action in self?.handle(action) }
        control.show(on: target.screen ?? NSScreen.underMouse ?? NSScreen.screens[0])
        self.control = control
        if control.model.camera { await setCamera(true) }
        if control.model.keystrokes { setKeystrokes(true) }
        waitingForRecord = true
        if control.model.microphone { Task { await setMicMonitor(true) } }

        let go = await withCheckedContinuation { pendingStart = $0 }
        waitingForRecord = false
        setMicMonitorOff()
        guard go else {
            tearDownAccessories()
            return
        }

        var microphone: AVCaptureDevice?
        if control.model.microphone {
            if await AVCaptureDevice.requestAccess(for: .audio) {
                microphone = CaptureDevices.microphone()
                if microphone == nil { HUD.show("No microphone found") }
            } else {
                HUD.show("Microphone access is off in System Settings")
            }
        }
        // Let the bar's window reach the window server before the shareable
        // content snapshot, so it can be excluded.
        try await Task.sleep(for: .milliseconds(100))

        do {
            let content = try await CaptureContent.make(for: target, excluding: [control.windowID, previews.windowID], windowAsRegion: true)
            let url = CaptureFiles.newURL(prefix: "Recording", ext: "mp4")
            let recording = try ScreenRecording(content: content, microphone: microphone, url: url)
            try await recording.start()
            self.recording = recording
            isRecording = true
            control.markRecording()
            if microphone != nil { control.levelSource = { recording.micLevel } }
            log.info("recording started")
        } catch {
            tearDownAccessories()
            throw error
        }
    }

    private func handle(_ action: RecordingControl.Action) {
        switch action {
        case .record, .cancel:
            let go = if case .record = action { true } else { false }
            pendingStart?.resume(returning: go)
            pendingStart = nil
        case .stop:
            Task { await stopRecording() }
        case .pause, .resume:
            togglePause()
        case let .camera(on):
            RecordingOptions.camera = on
            Task { await setCamera(on) }
        case let .microphone(on):
            RecordingOptions.microphone = on
            Task { await setMicMonitor(on) }
        case let .keystrokes(on):
            RecordingOptions.keystrokes = on
            setKeystrokes(on)
        case let .cameraDevice(id):
            RecordingOptions.cameraID = id.isEmpty ? nil : id
            control?.model.cameraID = id
            turnCameraOn()
            if let camera, let device = CaptureDevices.camera() { camera.setDevice(device) }
        case let .microphoneDevice(id):
            RecordingOptions.microphoneID = id.isEmpty ? nil : id
            control?.model.microphoneID = id
            RecordingOptions.microphone = true
            control?.model.microphone = true
            // Restart the meter on the new microphone.
            setMicMonitorOff()
            Task { await setMicMonitor(true) }
        case let .cameraStyle(style):
            RecordingOptions.cameraStyle = style
            control?.model.cameraStyle = style
            camera?.setStyle(style)
            turnCameraOn()
        case let .cameraSize(size):
            RecordingOptions.cameraSize = size
            control?.model.cameraSize = size
            camera?.setSize(size)
            turnCameraOn()
        }
    }

    /// Picking a camera, style or size in the menu also turns the camera on.
    private func turnCameraOn() {
        guard let control, !control.model.camera else { return }
        control.model.camera = true
        RecordingOptions.camera = true
        Task { await setCamera(true) }
    }

    private func setCamera(_ on: Bool) async {
        guard on else {
            camera?.hide()
            camera = nil
            return
        }
        guard camera == nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            HUD.show("Camera access is off in System Settings")
            control?.model.camera = false
            return
        }
        guard let control, camera == nil else { return }
        guard let device = CaptureDevices.camera(), let bubble = CameraBubble(device: device) else {
            HUD.show("No camera found")
            control.model.camera = false
            return
        }
        bubble.onStyleChange = { [weak control] style in
            RecordingOptions.cameraStyle = style
            control?.model.cameraStyle = style
        }
        bubble.onSizeChange = { [weak control] size in control?.model.cameraSize = size }
        bubble.show(in: recordArea)
        camera = bubble
    }

    /// Runs the microphone meter on the bar while it waits for Record.
    private func setMicMonitor(_ on: Bool) async {
        guard on else {
            setMicMonitorOff()
            return
        }
        guard micMonitor == nil, waitingForRecord else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            HUD.show("Microphone access is off in System Settings")
            return
        }
        guard let control, waitingForRecord, micMonitor == nil, control.model.microphone,
              let device = CaptureDevices.microphone(), let monitor = MicLevelMonitor(device: device)
        else { return }
        monitor.start()
        micMonitor = monitor
        control.levelSource = { monitor.level }
    }

    private func setMicMonitorOff() {
        micMonitor?.stop()
        micMonitor = nil
        control?.levelSource = nil
    }

    private func setKeystrokes(_ on: Bool) {
        guard on else {
            keystrokes?.stop()
            keystrokes = nil
            return
        }
        guard keystrokes == nil else { return }
        permissions.refresh()
        guard permissions.inputMonitoring else {
            permissions.requestInputMonitoring()
            control?.model.keystrokes = false
            return
        }
        let overlay = KeystrokeOverlay()
        if overlay.start(in: recordArea) { keystrokes = overlay }
    }

    func togglePause() {
        guard let recording, let control else { return }
        isPaused.toggle()
        if isPaused {
            recording.pause()
        } else {
            recording.resume()
        }
        control.markPaused(isPaused)
        log.info("recording \(self.isPaused ? "paused" : "resumed")")
    }

    private func stopRecording() async {
        guard let recording else { return }
        self.recording = nil
        isRecording = false
        isPaused = false
        tearDownAccessories()
        defer { previews.setHidden(false) }
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
        setMicMonitorOff()
        control?.hide()
        camera?.hide()
        keystrokes?.stop()
        control = nil
        camera = nil
        keystrokes = nil
    }
}
