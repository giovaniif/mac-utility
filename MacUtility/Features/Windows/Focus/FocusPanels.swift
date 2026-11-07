import AppKit
import KeyboardShortcuts
import os
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
        // Focus animates its panels itself; the system's own appear
        // animation would scale them on top of that.
        panel.animationBehavior = .none
        return panel
    }
}

private let leaderLog = Logger(subsystem: "com.giovani.MacUtility", category: "focus")

/// Drives a panel's SwiftUI enter and exit motion; the panel itself stays opaque.
@MainActor
@Observable
final class Presence {
    var isPresented = false
}

/// Near-solid panel fill. Materials in a panel of an inactive app (Focus never
/// activates) render translucent, and windows behind bleed through.
extension ShapeStyle where Self == Color {
    static var panelFill: Color { Color(nsColor: .windowBackgroundColor).opacity(0.97) }
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

/// The leader (⌃B by default), then one key. Invisible for 500 ms; after that a key guide
/// appears, with the shelf.
@MainActor
final class LeaderKey: NSObject, NSWindowDelegate {
    private unowned let controller: FocusController
    private let panel = FocusKeyPanel.make()
    private let keys = KeyMonitor()
    private var guideTask: Task<Void, Never>?
    private var repeatTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private let guide = Presence()
    private(set) var isArmed = false

    init(controller: FocusController) {
        self.controller = controller
        super.init()
        panel.delegate = self
    }

    func arm() {
        // Leader twice: hand the leader to the app, like tmux's prefix-prefix.
        if isArmed {
            disarm(animated: false)
            passThrough()
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        leaderLog.debug("leader armed")
        isArmed = true
        hideTask?.cancel()
        guide.isPresented = false
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

    /// `animated` lets a visible key guide ease out; passthrough needs the
    /// panel gone at once, so the posted keystroke reaches the app.
    func disarm(animated: Bool = true) {
        guard isArmed else { return }
        isArmed = false
        guideTask?.cancel()
        repeatTask?.cancel()
        keys.stop()
        controller.hideShelf()
        guard animated, guide.isPresented else {
            guide.isPresented = false
            panel.orderOut(nil)
            return
        }
        withAnimation(.easeIn(duration: 0.12)) { guide.isPresented = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled, let self, !self.isArmed else { return }
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        disarm()
    }

    private func showGuide(on screen: NSScreen) {
        guard isArmed else { return }
        let current = controller.summary(ofSet: controller.state.current)
        let hosting = NSHostingView(rootView: KeyGuideView(
            leader: KeyboardShortcuts.Name.focusLeaderLabel,
            setLabel: "Set \(current.number) · \(current.name)",
            presence: guide
        ))
        let size = hosting.fittingSize
        hosting.frame.size = size
        panel.contentView = NSView.container(for: hosting)
        let visible = screen.visibleFrame
        // The view carries its own margin for the shadow and the rise.
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 16, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        Task { @MainActor [guide] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { guide.isPresented = true }
        }
        controller.showShelf()
    }

    private func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> Bool {
        let shift = flags.contains(.shift)
        leaderLog.debug("leader key \(code) flags \(flags.rawValue) chars \(chars, privacy: .public)")
        // Normally the hotkey catches a second leader first; this is the fallback.
        if let leader = KeyboardShortcuts.getShortcut(for: .focusLeader),
           Int(code) == leader.carbonKeyCode, flags.intersection([.command, .control, .option, .shift]) == leader.modifiers {
            disarm(animated: false)
            passThrough()
            return true
        }
        if let number = KeyCode.digit(code) {
            finish { shift ? $0.send(to: number) : $0.goTo(number) }
            return true
        }
        switch code {
        case KeyCode.escape:
            disarm()
        case KeyCode.tab:
            finish { $0.back() }
        case KeyCode.left: pane(.left, shift: shift)
        case KeyCode.right: pane(.right, shift: shift)
        case KeyCode.up: pane(.up, shift: shift)
        case KeyCode.down: pane(.down, shift: shift)
        case KeyCode.returnKey, KeyCode.enter:
            finish { $0.toggleLayout() }
        case KeyCode.space:
            finish { $0.showSwitcher() }
        default:
            switch chars.lowercased() {
            case "h": pane(.left, shift: shift)
            case "j": pane(.down, shift: shift)
            case "k": pane(.up, shift: shift)
            case "l": pane(.right, shift: shift)
            case "v": finish { $0.split(.vertical) }
            case "s": finish { $0.split(.horizontal) }
            case "o": finish { $0.only() }
            case "t": finish { $0.toggleAxis() }
            case "r": finish { $0.showReplace() }
            case "f": finish { $0.toggleZoom() }
            case "\\": finish { $0.toggleFloat() }
            // Unbound keys close the guide and never reach the app.
            default: disarm()
            }
        }
        return true
    }

    /// h/j/k/l or arrows move between panes; with ⇧ they swap the two.
    /// The leader stays armed briefly so they can repeat.
    private func pane(_ direction: PaneDirection, shift: Bool) {
        shift ? controller.swapWindows() : controller.focusPane(direction)
        keepArmedBriefly()
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

    /// Posts the leader keystroke with the hotkey off, or our own hotkey
    /// would catch it. ⌃B ⌃B is how tmux and Emacs-style ⌃B still work.
    private func passThrough() {
        guard let leader = KeyboardShortcuts.getShortcut(for: .focusLeader) else { return }
        KeyboardShortcuts.disable(.focusLeader)
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            var flags = CGEventFlags()
            if leader.modifiers.contains(.control) { flags.insert(.maskControl) }
            if leader.modifiers.contains(.option) { flags.insert(.maskAlternate) }
            if leader.modifiers.contains(.shift) { flags.insert(.maskShift) }
            if leader.modifiers.contains(.command) { flags.insert(.maskCommand) }
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(leader.carbonKeyCode), keyDown: keyDown)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(150))
            if Feature.focus.isEnabled { KeyboardShortcuts.enable(.focusLeader) }
        }
    }
}

private struct KeyGuideView: View {
    let leader: String
    let setLabel: String
    let presence: Presence

    private var rows: [(String, String)] { [
        ("1–9", "Go to set"), ("Shift 1–9", "Move window to set"), ("⇥", "Previous set"),
        ("v", "Split side by side"), ("s", "Split top / bottom"), ("t", "Flip split direction"),
        ("o", "Only this window"),
        ("h j k l", "Focus pane"), ("Shift h j k l", "Swap panes"), ("↩", "Split ⇄ stacked"),
        ("Space", "Switcher"), ("r", "Replace this window"), ("f", "Zoom to full stage"),
        ("\\", "Float / unfloat"), (leader, "Send \(leader) to app"), ("esc", "Cancel"),
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(leader)
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
                ForEach(0..<(rows.count + 2) / 3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3) { column in
                            let item = rows.indices.contains(row * 3 + column) ? rows[row * 3 + column] : ("", "")
                            HStack(spacing: 10) {
                                Text(item.0)
                                    .font(.callout.weight(.semibold))
                                    .frame(minWidth: 84)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                Text(item.1).font(.callout)
                            }
                            .opacity(item.0.isEmpty ? 0 : 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 780)
        .background(.panelFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        // Rises from the bottom edge, like a sheet.
        .scaleEffect(presence.isPresented ? 1 : 0.97, anchor: .bottom)
        .offset(y: presence.isPresented ? 0 : 18)
        .opacity(presence.isPresented ? 1 : 0)
        .padding(24)
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

/// Miniature of a set at the display's proportions: one or two tiles with
/// the window's last snapshot, or its app icon until there is one.
struct SetPreview: View {
    let set: SetSummary
    let thumbnails: [WindowID: NSImage]
    var cornerRadius: CGFloat = 10

    private static let aspect: CGFloat = {
        guard let frame = NSScreen.screens.first?.frame, frame.height > 0 else { return 16 / 10 }
        return frame.width / frame.height
    }()

    var body: some View {
        Color.clear
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay {
                if set.isEmpty {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                } else {
                    GeometryReader { proxy in
                        let inset = proxy.size.width * 0.035
                        let gap = inset * 0.8
                        let inner = proxy.size.width - inset * 2
                        HStack(spacing: gap) {
                            if set.isSplit, set.windows.count == 2 {
                                tile(set.windows[0]).frame(width: (inner - gap) * set.ratio)
                                tile(set.windows[1])
                            } else if let first = set.windows.first {
                                tile(first)
                            }
                        }
                        .padding(inset)
                    }
                    .background(Color(red: 0.2, green: 0.24, blue: 0.29))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
    }

    private func tile(_ window: WindowSummary) -> some View {
        // Color.clear + overlay keeps a filling image inside the tile's frame.
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                if let image = thumbnails[window.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let icon = window.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 40, height: 40)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.45, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

