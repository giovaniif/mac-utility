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
    @ObservationIgnored private var recordArea = CGRect.zero
    /// Waiting for Record or Cancel on the bar.
    @ObservationIgnored private var pendingStart: CheckedContinuation<Bool, Never>?

    init(permissions: Permissions) {
        self.permissions = permissions
    }

    #if DEBUG
    /// Launch with `-testPreview <file>` to show a preview without capturing.
    func showTestPreview(_ url: URL) {
        let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        previews.show(CaptureResult(kind: .screenshot, url: url, thumbnail: image))
    }
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
        var shown = false
        defer { if !shown { previews.setHidden(false) } }
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
        shown = true
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

        let go = await withCheckedContinuation { pendingStart = $0 }
        guard go else {
            tearDownAccessories()
            return
        }

        var micAllowed = false
        if control.model.microphone {
            micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            if !micAllowed { HUD.show("Microphone access is off in System Settings") }
        }
        // Let the bar's window reach the window server before the shareable
        // content snapshot, so it can be excluded.
        try await Task.sleep(for: .milliseconds(100))

        do {
            let content = try await CaptureContent.make(for: target, excluding: [control.windowID])
            let url = CaptureFiles.newURL(prefix: "Recording", ext: "mp4")
            let recording = try ScreenRecording(content: content, microphone: micAllowed, url: url)
            try await recording.start()
            self.recording = recording
            isRecording = true
            control.markRecording()
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
        case let .camera(on):
            RecordingOptions.camera = on
            Task { await setCamera(on) }
        case let .microphone(on):
            RecordingOptions.microphone = on
        case let .keystrokes(on):
            RecordingOptions.keystrokes = on
            setKeystrokes(on)
        }
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
        guard control != nil, let bubble = CameraBubble() else { return }
        bubble.show(in: recordArea)
        camera = bubble
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
