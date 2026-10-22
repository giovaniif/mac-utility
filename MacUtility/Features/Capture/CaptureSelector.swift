import AppKit

/// What to capture. Rects are in global AppKit coordinates (origin at the
/// bottom-left of the primary display).
enum CaptureTarget: Sendable {
    case area(CGDirectDisplayID, CGRect)
    case window(CGWindowID, CGRect)
    case display(CGDirectDisplayID)

    @MainActor
    var screen: NSScreen? {
        switch self {
        case let .area(id, _), let .display(id): NSScreen.screens.first { $0.displayID == id }
        case let .window(_, rect): NSScreen.screens.first { $0.frame.intersects(rect) }
        }
    }

    /// Area on screen the capture covers.
    @MainActor
    var rect: CGRect {
        switch self {
        case let .area(_, rect), let .window(_, rect): rect
        case .display: screen?.frame ?? .zero
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? main
    }
}

/// Crosshair overlay on every display. Drag to pick an area, Space switches
/// to picking a window, Return takes the whole display (a click does too when
/// recording). Esc cancels.
@MainActor
final class CaptureSelector {
    enum Mode { case screenshot, recording }

    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?

    func select(_ mode: Mode) async -> CaptureTarget? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let shared = SelectionState(mode: mode)
            for screen in NSScreen.screens {
                let window = SelectionWindow(screen: screen, state: shared) { [weak self] target in
                    self?.finish(target)
                }
                windows.append(window)
                window.fadeIn(duration: 0.12)
            }
            NSApp.activate()
            (windows.first { $0.screen == NSScreen.underMouse } ?? windows.first)?.makeKey()
        }
    }

    private func finish(_ target: CaptureTarget?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        continuation?.resume(returning: target)
        continuation = nil
    }
}

/// State shared by the overlays on every display, so window mode and
/// hovering stay in sync across them.
@MainActor
private final class SelectionState {
    let mode: CaptureSelector.Mode
    var pickingWindow = false
    var hoveredWindow: (id: CGWindowID, rect: CGRect)?
    var views: [SelectionView] = []

    init(mode: CaptureSelector.Mode) { self.mode = mode }

    func redraw() { views.forEach { $0.needsDisplay = true } }

    /// Topmost normal window under the point, from other apps.
    func windowAt(_ point: CGPoint) -> (id: CGWindowID, rect: CGRect)? {
        guard let primary = NSScreen.screens.first else { return nil }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            // CoreGraphics window bounds have a top-left origin.
            let rect = CGRect(x: cgRect.minX, y: primary.frame.maxY - cgRect.maxY, width: cgRect.width, height: cgRect.height)
            if rect.contains(point) { return (id, rect) }
        }
        return nil
    }
}

private final class SelectionWindow: NSPanel {
    init(screen: NSScreen, state: SelectionState, onFinish: @escaping (CaptureTarget?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = SelectionView(screen: screen, state: state, onFinish: onFinish)
        state.views.append(view)
        contentView = view
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    private let targetScreen: NSScreen
    private let state: SelectionState
    private let onFinish: (CaptureTarget?) -> Void
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(screen: NSScreen, state: SelectionState, onFinish: @escaping (CaptureTarget?) -> Void) {
        targetScreen = screen
        self.state = state
        self.onFinish = onFinish
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .cursorUpdate, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private var global: (CGPoint) -> CGPoint {
        let origin = targetScreen.frame.origin
        return { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
    }

    private var selection: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x), y: min(dragStart.y, dragCurrent.y),
            width: abs(dragStart.x - dragCurrent.x), height: abs(dragStart.y - dragCurrent.y)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        guard state.pickingWindow else { return }
        let hovered = state.windowAt(global(convert(event.locationInWindow, from: nil)))
        if hovered?.id != state.hoveredWindow?.id {
            state.hoveredWindow = hovered
            state.redraw()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if state.pickingWindow {
            if let hovered = state.hoveredWindow {
                onFinish(.window(hovered.id, hovered.rect))
            }
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = CGPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selection else { return }
        dragStart = nil
        dragCurrent = nil
        if rect.width >= 4, rect.height >= 4 {
            onFinish(.area(targetScreen.displayID ?? 0, rect.offsetBy(dx: targetScreen.frame.minX, dy: targetScreen.frame.minY).integral))
        } else if state.mode == .recording {
            onFinish(.display(targetScreen.displayID ?? 0))
        } else {
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onFinish(nil)
        case 49: // Space
            state.pickingWindow.toggle()
            state.hoveredWindow = state.pickingWindow ? state.windowAt(NSEvent.mouseLocation) : nil
            state.redraw()
        case 36, 76: // Return
            onFinish(.display((NSScreen.underMouse ?? targetScreen).displayID ?? 0))
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        var highlight: CGRect?
        if state.pickingWindow, let hovered = state.hoveredWindow {
            highlight = hovered.rect.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        } else {
            highlight = selection
        }

        if let highlight {
            NSColor.clear.setFill()
            highlight.fill(using: .copy)
            let border = NSBezierPath(rect: highlight.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.stroke()
            if state.pickingWindow {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                highlight.fill(using: .sourceOver)
            } else {
                drawSizeLabel(for: highlight)
            }
        } else {
            drawHint()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        var origin = CGPoint(x: rect.maxX - size.width - 8, y: rect.minY - size.height - 10)
        if origin.y < 4 { origin.y = rect.minY + 6 }
        let background = CGRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        label.draw(at: origin, withAttributes: attributes)
    }

    private func drawHint() {
        guard targetScreen == NSScreen.underMouse else { return }
        let hint: String = switch state.mode {
        case .screenshot: "Drag to capture an area · Space for a window · Esc to cancel"
        case .recording: "Drag to record an area · Space for a window · Click or Return for the full screen · Esc to cancel"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = hint as NSString
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let background = CGRect(x: origin.x - 14, y: origin.y - 8, width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: background, xRadius: 10, yRadius: 10).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}
