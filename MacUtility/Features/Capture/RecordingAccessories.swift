import AppKit
import AVFoundation
import Observation
import SwiftUI

/// User choices for what goes on top of a recording, stored in UserDefaults.
enum RecordingOptions {
    static let cameraKey = "recording.camera"
    static let microphoneKey = "recording.microphone"
    static let keystrokesKey = "recording.keystrokes"

    static var camera: Bool { UserDefaults.standard.bool(forKey: cameraKey) }
    static var microphone: Bool { UserDefaults.standard.bool(forKey: microphoneKey) }
    static var keystrokes: Bool { UserDefaults.standard.bool(forKey: keystrokesKey) }
}

/// Round, draggable camera bubble. It's a normal on-screen window, so the
/// recording picks it up like anything else.
@MainActor
final class CameraBubble {
    private let session = AVCaptureSession()
    private let panel: NSPanel
    private static let size: CGFloat = 200

    init?() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return nil }
        session.addInput(input)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.cornerRadius = Self.size / 2
        preview.masksToBounds = true
        preview.borderWidth = 3
        preview.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        // Mirror like a selfie camera.
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        view.layer?.addSublayer(preview)
        panel.contentView = view
    }

    func show(in rect: CGRect) {
        let inset: CGFloat = 24
        let origin = CGPoint(x: rect.maxX - Self.size - inset, y: rect.minY + inset)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        // startRunning/stopRunning block, so keep them off the main thread.
        nonisolated(unsafe) let session = session
        Task.detached { session.startRunning() }
    }

    func hide() {
        panel.orderOut(nil)
        // startRunning/stopRunning block, so keep them off the main thread.
        nonisolated(unsafe) let session = session
        Task.detached { session.stopRunning() }
    }
}

@MainActor
@Observable
final class KeystrokeModel {
    var text = ""
}

/// Shows the keys being pressed as a pill near the bottom of the recorded
/// area. Listens through a listen-only event tap, so keys still reach apps.
@MainActor
final class KeystrokeOverlay {
    private let model = KeystrokeModel()
    private let panel: NSPanel
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var clearTask: Task<Void, Never>?
    private var area = CGRect.zero

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: KeystrokeView(model: model))
    }

    /// Returns false if the event tap couldn't be created.
    func start(in rect: CGRect) -> Bool {
        area = rect
        panel.setFrame(NSRect(x: rect.midX - 300, y: rect.minY + 40, width: 600, height: 80), display: true)
        panel.orderFrontRegardless()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keystrokeCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        clearTask?.cancel()
        model.text = ""
        panel.orderOut(nil)
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func record(label: String, isShortcut: Bool) {
        guard !label.isEmpty else { return }
        // Plain typing accumulates into a word; shortcuts replace it.
        if isShortcut || model.text.count > 24 || label.count > 1 {
            model.text = label
        } else {
            model.text += label
        }
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.model.text = ""
        }
    }

    nonisolated fileprivate static func label(for event: CGEvent) -> String {
        let flags = event.flags
        var label = ""
        if flags.contains(.maskControl) { label += "⌃" }
        if flags.contains(.maskAlternate) { label += "⌥" }
        if flags.contains(.maskShift) { label += "⇧" }
        if flags.contains(.maskCommand) { label += "⌘" }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if let special = specialKeys[keyCode] {
            return label + special
        }
        let modified = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
        guard !characters.isEmpty else { return label }
        if modified {
            return label + characters.uppercased()
        }
        // Shift is already reflected in the typed character.
        return NSEvent(cgEvent: event)?.characters ?? characters
    }

    nonisolated private static let specialKeys: [Int64: String] = [
        36: "⏎", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

private func keystrokeCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let address = UInt(bitPattern: userInfo)
    let isKey = type == .keyDown
    let label = isKey ? KeystrokeOverlay.label(for: event) : ""
    let flags = event.flags
    let isShortcut = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
    // The tap's run loop source is on the main run loop.
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let overlay = Unmanaged<KeystrokeOverlay>.fromOpaque(pointer).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput: overlay.reenable()
        case .keyDown: overlay.record(label: label, isShortcut: isShortcut)
        default: break
        }
    }
    return Unmanaged.passUnretained(event)
}

private struct KeystrokeView: View {
    let model: KeystrokeModel

    var body: some View {
        VStack {
            Spacer()
            if !model.text.isEmpty {
                Text(model.text)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.text.isEmpty)
    }
}

@MainActor
@Observable
final class RecordingControlModel {
    var started = Date()
}

/// Small floating bar with elapsed time and a Stop button. It's excluded from
/// the recording.
@MainActor
final class RecordingControl {
    private let model = RecordingControlModel()
    private let panel: NSPanel

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(onStop: @escaping @MainActor () -> Void) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 170, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingControlView(model: model, onStop: onStop))
    }

    func show(on screen: NSScreen) {
        model.started = Date()
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - 85, y: frame.maxY - 52))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private struct RecordingControlView: View {
    let model: RecordingControlModel
    let onStop: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: model.started, by: 1)) { context in
                Text(Duration.seconds(context.date.timeIntervalSince(model.started)), format: .time(pattern: .minuteSecond))
                    .font(.system(.body, design: .monospaced))
            }
            Spacer(minLength: 0)
            Button { onStop() } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop recording")
        }
        .padding(.horizontal, 12)
        .frame(width: 170, height: 40)
        .background(.regularMaterial, in: Capsule())
    }
}
