import AppKit
import KeyboardShortcuts
import SwiftUI

/// Borderless panel that takes key focus without activating Mac Utility, so
/// the app you were in stays frontmost (same trick as the clipboard panel).
final class FocusKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static func make() -> FocusKeyPanel {
        let panel = FocusKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

/// Local keyDown monitor whose handler decides whether to swallow the key.
@MainActor
final class KeyMonitor {
    private var monitor: Any?

    func start(_ handler: @escaping @MainActor (_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""
            let handled = MainActor.assumeIsolated { handler(keyCode, flags, chars) }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

enum KeyCode {
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    /// Number row 1–9 by key position, so ⇧ and keyboard layouts don't matter.
    static func digit(_ code: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][code]
    }
}

// MARK: - Leader key

/// ⌃Space, then one key. Invisible for 500 ms; after that a key guide
/// appears, with the shelf.
@MainActor
final class LeaderKey: NSObject, NSWindowDelegate {
    private unowned let controller: FocusController
    private let panel = FocusKeyPanel.make()
    private let keys = KeyMonitor()
    private var guideTask: Task<Void, Never>?
    private var repeatTask: Task<Void, Never>?
    private(set) var isArmed = false

    init(controller: FocusController) {
        self.controller = controller
        super.init()
        panel.delegate = self
    }

    func arm() {
        // Leader twice: hand ⌃Space to the app, like tmux's prefix-prefix.
        if isArmed {
            disarm()
            passThrough()
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        isArmed = true
        panel.contentView = NSView()
        panel.alphaValue = 0
        panel.setFrame(CGRect(x: screen.frame.midX, y: screen.frame.minY, width: 1, height: 1), display: false)
        panel.makeKeyAndOrderFront(nil)
        keys.start { [weak self] code, flags, chars in self?.handle(code, flags, chars) ?? false }
        guideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.showGuide(on: screen)
        }
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        guideTask?.cancel()
        repeatTask?.cancel()
        keys.stop()
        panel.orderOut(nil)
        controller.hideShelf()
    }

    func windowDidResignKey(_ notification: Notification) {
        disarm()
    }

    private func showGuide(on screen: NSScreen) {
        guard isArmed else { return }
        let current = controller.summary(ofSet: controller.state.current)
        let hosting = NSHostingView(rootView: KeyGuideView(setLabel: "Set \(current.number) · \(current.name)"))
        let size = hosting.fittingSize
        hosting.frame.size = size
        panel.contentView = NSView.container(for: hosting)
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 40, width: size.width, height: size.height), display: true)
        panel.fadeIn(duration: 0.15, rise: 8, makeKey: true)
        controller.showShelf()
    }

    private func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> Bool {
        let shift = flags.contains(.shift)
        if let number = KeyCode.digit(code) {
            finish { shift ? $0.send(to: number) : $0.goTo(number) }
            return true
        }
        switch code {
        case KeyCode.escape:
            disarm()
        case KeyCode.tab:
            finish { $0.back() }
        case KeyCode.left, KeyCode.right:
            shift ? controller.swapWindows() : controller.focusOther()
            keepArmedBriefly()
        case KeyCode.returnKey, KeyCode.enter:
            finish { $0.toggleLayout() }
        case KeyCode.space where flags.contains(.control):
            disarm()
            passThrough()
        case KeyCode.space:
            finish { $0.showSwitcher() }
        default:
            switch chars.lowercased() {
            case "r": finish { $0.showReplace() }
            case "f": finish { $0.toggleZoom() }
            case "\\": finish { $0.toggleFloat() }
            // Unbound keys close the guide and never reach the app.
            default: disarm()
            }
        }
        return true
    }

    private func finish(_ action: (FocusController) -> Void) {
        disarm()
        action(controller)
    }

    /// After an arrow the leader stays armed briefly so arrows can repeat.
    private func keepArmedBriefly() {
        guideTask?.cancel()
        repeatTask?.cancel()
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.disarm()
        }
    }

    /// Posts ⌃Space with the hotkey off, or our own hotkey would catch it.
    private func passThrough() {
        KeyboardShortcuts.disable(.focusLeader)
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(KeyCode.space), keyDown: keyDown)
                event?.flags = .maskControl
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(150))
            if Feature.focus.isEnabled { KeyboardShortcuts.enable(.focusLeader) }
        }
    }
}

private struct KeyGuideView: View {
    let setLabel: String

    private let rows: [(String, String)] = [
        ("1–9", "Go to set"), ("⇧1–9", "Send window to set"), ("⇥", "Previous set"),
        ("← →", "Focus other window"), ("⇧← →", "Swap windows"), ("↩", "Split ⇄ stacked"),
        ("Space", "Switcher"), ("R", "Replace this window"), ("F", "Zoom to full stage"),
        ("\\", "Float / unfloat"), ("⌃Space", "Send ⌃Space to app"), ("esc", "Cancel"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("⌃Space")
                    .font(.callout.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                Text("Focus").font(.headline)
                Spacer()
                Text(setLabel).font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                ForEach(0..<4) { row in
                    GridRow {
                        ForEach(0..<3) { column in
                            let item = rows[row * 3 + column]
                            HStack(spacing: 10) {
                                Text(item.0)
                                    .font(.callout.weight(.semibold))
                                    .frame(minWidth: 44)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                Text(item.1).font(.callout)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1)))
    }
}

// MARK: - HUD

/// Bottom-of-stage card after a switch, a new set or a Replace.
@MainActor
enum FocusHUD {
    struct Content {
        let number: Int
        let title: String
        let subtitle: String
        let occupied: [Int]
        let current: Int
        let undo: (() -> Void)?
    }

    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ content: Content, on screen: NSScreen) {
        let hosting = NSHostingView(rootView: FocusHUDView(content: content) { hide() })
        let size = hosting.fittingSize
        hosting.frame.size = size
        let panel = Self.panel ?? FocusKeyPanel.make()
        panel.level = .statusBar
        panel.ignoresMouseEvents = content.undo == nil
        panel.contentView = NSView.container(for: hosting)
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 56, width: size.width, height: size.height), display: true)
        panel.fadeIn(duration: 0.15, rise: 10)
        Self.panel = panel

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(content.undo == nil ? 1.2 : 5))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    static func hide() {
        hideTask?.cancel()
        panel?.fadeOut(duration: 0.25)
    }
}

private struct FocusHUDView: View {
    let content: FocusHUD.Content
    let close: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SetBadge(number: content.number, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(.headline)
                Text(content.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let undo = content.undo {
                Button("Undo") {
                    undo()
                    close()
                }
                .controlSize(.large)
            }
            OccupiedStrip(occupied: content.occupied, current: content.current)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(minWidth: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1)))
        .fixedSize()
    }
}

// MARK: - Shared pieces

struct SetBadge: View {
    let number: Int
    var size: CGFloat = 22

    var body: some View {
        Text("\(number)")
            .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
            .frame(width: size, height: size)
            .background(Color.primary, in: RoundedRectangle(cornerRadius: size * 0.27))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
    }
}

struct OccupiedStrip: View {
    let occupied: [Int]
    let current: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(occupied, id: \.self) { number in
                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
                    .background(number == current ? Color.accentColor : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(number == current ? Color.white : Color.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sets with windows: \(occupied.map(String.init).joined(separator: ", "))")
    }
}

/// Miniature of a set: one or two tiles with thumbnails or app icons.
struct SetPreview: View {
    let set: SetSummary
    let thumbnails: [WindowID: NSImage]

    var body: some View {
        if set.isEmpty {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.secondary)
                .overlay(Text("Empty").font(.caption).foregroundStyle(.secondary))
        } else {
            HStack(spacing: 6) {
                ForEach(set.isSplit ? set.windows : Array(set.windows.prefix(1))) { window in
                    tile(window)
                }
            }
            .padding(8)
            .background(Color(red: 0.24, green: 0.29, blue: 0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private func tile(_ window: WindowSummary) -> some View {
        ZStack {
            Color.white
            if let image = thumbnails[window.id] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 36, height: 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Menu bar image: the numbers of sets with windows, current one filled.
enum SetsMenuBarImage {
    static func make(occupied: [Int], current: Int) -> NSImage {
        let cell: CGFloat = 15
        let spacing: CGFloat = 2
        let width = CGFloat(max(occupied.count, 1)) * (cell + spacing) - spacing
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            for (index, number) in occupied.enumerated() {
                let rect = CGRect(x: CGFloat(index) * (cell + spacing), y: 0.5, width: cell, height: 15)
                let text = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: NSColor.black])
                let size = text.size()
                let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                if number == current {
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
                    // Knock the digit out of the filled square.
                    NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                    text.draw(at: point)
                    NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
                } else {
                    text.draw(at: point)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
