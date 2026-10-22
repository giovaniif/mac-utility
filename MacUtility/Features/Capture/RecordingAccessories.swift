import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Last choices on the recording bar, remembered for the next recording.
enum RecordingOptions {
    static let cameraKey = "recording.camera"
    static let microphoneKey = "recording.microphone"
    static let keystrokesKey = "recording.keystrokes"

    static var camera: Bool {
        get { UserDefaults.standard.bool(forKey: cameraKey) }
        set { UserDefaults.standard.set(newValue, forKey: cameraKey) }
    }
    static var microphone: Bool {
        get { UserDefaults.standard.bool(forKey: microphoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: microphoneKey) }
    }
    static var keystrokes: Bool {
        get { UserDefaults.standard.bool(forKey: keystrokesKey) }
        set { UserDefaults.standard.set(newValue, forKey: keystrokesKey) }
    }
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
        panel.fadeIn(duration: 0.2)
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
        panel.contentView = NSView.hosting(KeystrokeView(model: model))
    }

    /// Returns false if the event tap couldn't be created.
    func start(in rect: CGRect) -> Bool {
        area = rect
        panel.setFrame(NSRect(x: rect.midX - 300, y: rect.minY + 40, width: 600, height: 80), display: true)
        panel.fadeIn(duration: 0.2)

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
    var recording = false
    var camera = RecordingOptions.camera
    var microphone = RecordingOptions.microphone
    var keystrokes = RecordingOptions.keystrokes
}

/// CleanShot-style floating bar. Before recording it holds the camera,
/// microphone and keystroke switches plus Record; while recording it shows
/// the elapsed time and Stop. It's excluded from the recording.
@MainActor
final class RecordingControl {
    enum Action { case record, stop, cancel, camera(Bool), microphone(Bool), keystrokes(Bool) }

    let model = RecordingControlModel()
    private let panel: NSPanel
    private static let size = CGSize(width: 300, height: 48)

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(onAction: @escaping @MainActor (Action) -> Void) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        panel.contentView = NSView.hosting(RecordingControlView(model: model, onAction: onAction))
    }

    func show(on screen: NSScreen) {
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 12))
        panel.fadeIn(duration: 0.2, rise: -8)
    }

    func markRecording() {
        model.started = Date()
        withAnimation(.spring(duration: 0.3)) { model.recording = true }
    }

    func hide() { panel.orderOut(nil) }
}

private struct RecordingControlView: View {
    let model: RecordingControlModel
    let onAction: @MainActor (RecordingControl.Action) -> Void

    var body: some View {
        HStack(spacing: 6) {
            OptionButton(on: model.camera, onIcon: "video.fill", offIcon: "video.slash", help: "Camera") {
                model.camera.toggle()
                onAction(.camera(model.camera))
            }
            OptionButton(on: model.microphone, onIcon: "mic.fill", offIcon: "mic.slash", help: model.recording ? "Microphone can only change before recording" : "Microphone") {
                model.microphone.toggle()
                onAction(.microphone(model.microphone))
            }
            .disabled(model.recording)
            OptionButton(on: model.keystrokes, onIcon: "keyboard.fill", offIcon: "keyboard", help: "Show keystrokes") {
                model.keystrokes.toggle()
                onAction(.keystrokes(model.keystrokes))
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            if model.recording {
                Circle().fill(.red).frame(width: 9, height: 9)
                    .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
                TimelineView(.periodic(from: model.started, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(model.started)), format: .time(pattern: .minuteSecond))
                        .font(.system(.body, design: .monospaced))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Button { onAction(.stop) } label: {
                    Image(systemName: "stop.fill").frame(width: 30, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Stop recording")
                .transition(.scale.combined(with: .opacity))
            } else {
                Spacer(minLength: 0)
                Button { onAction(.record) } label: {
                    Label("Record", systemImage: "record.circle").frame(height: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .transition(.scale.combined(with: .opacity))
                Button { onAction(.cancel) } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 300, height: 48)
        .background(.regularMaterial, in: Capsule())
        .animation(.spring(duration: 0.3), value: model.recording)
    }
}

private struct OptionButton: View {
    let on: Bool
    let onIcon: String
    let offIcon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? onIcon : offIcon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 30)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(on ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(duration: 0.25), value: on)
    }
}
