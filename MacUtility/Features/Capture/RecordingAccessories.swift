import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Last choices on the recording bar, remembered for the next recording.
enum RecordingOptions {
    static let cameraKey = "recording.camera"
    static let microphoneKey = "recording.microphone"
    static let keystrokesKey = "recording.keystrokes"
    static let cameraIDKey = "recording.cameraDevice"
    static let microphoneIDKey = "recording.microphoneDevice"
    static let cameraStyleKey = "recording.cameraStyle"
    static let cameraSizeKey = "recording.cameraSize"
    static let cameraPositionKey = "recording.cameraPosition"
    static let lastAreaKey = "recording.lastArea"

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
    /// Unique ID of the chosen camera; nil follows the system's.
    static var cameraID: String? {
        get { UserDefaults.standard.string(forKey: cameraIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: cameraIDKey) }
    }
    /// Unique ID of the chosen microphone; nil follows the system's input.
    static var microphoneID: String? {
        get { UserDefaults.standard.string(forKey: microphoneIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: microphoneIDKey) }
    }
    static var cameraStyle: CameraStyle {
        get { CameraStyle(rawValue: UserDefaults.standard.string(forKey: cameraStyleKey) ?? "") ?? .circle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cameraStyleKey) }
    }
    /// How many points across the bubble is.
    static var cameraSize: CGFloat {
        get {
            let size = UserDefaults.standard.double(forKey: cameraSizeKey)
            guard size > 0 else { return 200 }
            return min(max(size, CameraBubble.sizes.lowerBound), CameraBubble.sizes.upperBound)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: cameraSizeKey) }
    }
    /// Where the bubble's middle was left, as a fraction of the recorded area.
    static var cameraPosition: CGPoint? {
        get {
            guard let values = UserDefaults.standard.array(forKey: cameraPositionKey) as? [Double], values.count == 2 else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
        set {
            if let newValue {
                UserDefaults.standard.set([Double(newValue.x), Double(newValue.y)], forKey: cameraPositionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: cameraPositionKey)
            }
        }
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
    var paused = false
    /// Recorded time before the current run, i.e. up to the last pause.
    var elapsedBefore: TimeInterval = 0

    func elapsed(at date: Date) -> TimeInterval {
        paused ? elapsedBefore : elapsedBefore + date.timeIntervalSince(started)
    }
    var camera = RecordingOptions.camera
    var microphone = RecordingOptions.microphone
    var keystrokes = RecordingOptions.keystrokes

    var cameras: [DeviceChoice] = []
    var microphones: [DeviceChoice] = []
    /// Chosen device IDs; empty follows the system default.
    var cameraID = RecordingOptions.cameraID ?? ""
    var microphoneID = RecordingOptions.microphoneID ?? ""
    var cameraStyle = RecordingOptions.cameraStyle
    var cameraSize = RecordingOptions.cameraSize
    /// Microphone input level, 0...1, while the microphone is on.
    var micLevel: Float = 0

    /// The chosen camera, or "" (Automatic) when it's unplugged.
    var cameraSelection: String { cameras.contains { $0.id == cameraID } ? cameraID : "" }
    var microphoneSelection: String { microphones.contains { $0.id == microphoneID } ? microphoneID : "" }

    func reloadDevices() {
        cameras = CaptureDevices.cameras.map(DeviceChoice.init)
        microphones = CaptureDevices.microphones.map(DeviceChoice.init)
    }
}

/// CleanShot-style floating bar. Before recording it holds the camera,
/// microphone and keystroke switches plus Record; while recording it shows
/// the elapsed time and Stop. The arrows beside camera and microphone pick
/// the device, and the camera's look. It's excluded from the recording.
@MainActor
final class RecordingControl {
    enum Action {
        case record, stop, cancel, pause, resume
        case camera(Bool), microphone(Bool), keystrokes(Bool)
        case cameraDevice(String), microphoneDevice(String)
        case cameraStyle(CameraStyle), cameraSize(CGFloat)
    }

    let model = RecordingControlModel()
    private let panel: NSPanel
    private static let size = CGSize(width: 396, height: 48)
    private var tokens: [NSObjectProtocol] = []
    private var levelTask: Task<Void, Never>?

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    /// Read a few times a second for the microphone meter; nil stops it.
    var levelSource: (@MainActor () -> Float)? {
        didSet { watchLevel() }
    }

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

        model.reloadDevices()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.model.reloadDevices() }
            })
        }
    }

    func show(on screen: NSScreen) {
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 12))
        panel.fadeIn(duration: 0.2, rise: -8)
    }

    func markRecording() {
        model.started = Date()
        model.elapsedBefore = 0
        model.paused = false
        withAnimation(.spring(duration: 0.3)) { model.recording = true }
    }

    func markPaused(_ paused: Bool) {
        let now = Date()
        if paused {
            model.elapsedBefore = model.elapsed(at: now)
        } else {
            model.started = now
        }
        model.paused = paused
    }

    func hide() {
        panel.orderOut(nil)
        levelSource = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    private func watchLevel() {
        levelTask?.cancel()
        model.micLevel = 0
        guard levelSource != nil else { return }
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let source = levelSource else { return }
                model.micLevel = source()
            }
        }
    }
}

private struct RecordingControlView: View {
    let model: RecordingControlModel
    let onAction: @MainActor (RecordingControl.Action) -> Void

    var body: some View {
        HStack(spacing: 4) {
            OptionButton(on: model.camera, onIcon: "video.fill", offIcon: "video.slash", help: "Camera") {
                model.camera.toggle()
                onAction(.camera(model.camera))
            }
            DeviceMenu(help: "Choose camera and style") { cameraMenu }

            OptionButton(on: model.microphone, onIcon: "mic.fill", offIcon: "mic.slash", help: model.recording ? "Microphone can only change before recording" : "Microphone", level: model.microphone ? model.micLevel : nil) {
                model.microphone.toggle()
                onAction(.microphone(model.microphone))
            }
            .disabled(model.recording)
            DeviceMenu(help: model.recording ? "Microphone can only change before recording" : "Choose microphone") { microphoneMenu }
                .disabled(model.recording)

            OptionButton(on: model.keystrokes, onIcon: "keyboard.fill", offIcon: "keyboard", help: "Show keystrokes") {
                model.keystrokes.toggle()
                onAction(.keystrokes(model.keystrokes))
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            if model.recording {
                if model.paused {
                    Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.orange)
                } else {
                    Circle().fill(.red).frame(width: 9, height: 9)
                        .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
                }
                TimelineView(.periodic(from: model.started, by: 1)) { context in
                    Text(Duration.seconds(model.elapsed(at: context.date)), format: .time(pattern: .minuteSecond))
                        .font(.system(.body, design: .monospaced))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Button { onAction(model.paused ? .resume : .pause) } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 30, height: 24)
                }
                .buttonStyle(.bordered)
                .help(model.paused ? "Resume recording" : "Pause recording")
                .transition(.scale.combined(with: .opacity))
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
        .frame(width: 396, height: 48)
        .background(.regularMaterial, in: Capsule())
        .animation(.spring(duration: 0.3), value: model.recording)
    }

    @ViewBuilder
    private var cameraMenu: some View {
        Section("Camera") {
            Picker("Camera", selection: Binding(
                get: { model.cameraSelection },
                set: { onAction(.cameraDevice($0)) }
            )) {
                Text("Automatic").tag("")
                ForEach(model.cameras) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("Style") {
            Picker("Style", selection: Binding(
                get: { model.cameraStyle },
                set: { onAction(.cameraStyle($0)) }
            )) {
                ForEach(CameraStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbol).tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("Size") {
            ForEach(Self.sizes, id: \.size) { preset in
                Toggle(preset.title, isOn: Binding(
                    get: { abs(model.cameraSize - preset.size) < 1 },
                    set: { _ in onAction(.cameraSize(preset.size)) }
                ))
            }
        }
        Section {
            Text("Drag the bubble to move it, double-click it for the next style, scroll or pinch on it to resize.")
        }
    }

    @ViewBuilder
    private var microphoneMenu: some View {
        Section("Microphone") {
            Picker("Microphone", selection: Binding(
                get: { model.microphoneSelection },
                set: { onAction(.microphoneDevice($0)) }
            )) {
                Text("System Default").tag("")
                ForEach(model.microphones) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private static let sizes: [(title: String, size: CGFloat)] = [("Small", 150), ("Medium", 200), ("Large", 280)]
}

/// The small arrow beside an option that opens its menu.
private struct DeviceMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 16, height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct OptionButton: View {
    let on: Bool
    let onIcon: String
    let offIcon: String
    let help: String
    /// Input level shown filling the button from the bottom, if any.
    var level: Float?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? onIcon : offIcon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 30)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(alignment: .bottom) {
                    if let level {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(height: 30 * CGFloat(level))
                            .animation(.linear(duration: 0.08), value: level)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(on ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(duration: 0.25), value: on)
    }
}
