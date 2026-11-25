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
/// recording). Esc cancels. Recording starts on the last area recorded: drag
/// it or its edges to adjust, then click inside it or press Return.
@MainActor
final class CaptureSelector {
    enum Mode { case screenshot, recording }

    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?
    private var mode = Mode.screenshot

    func select(_ mode: Mode) async -> CaptureTarget? {
        finish(nil)
        self.mode = mode
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let shared = SelectionState(mode: mode)
            if mode == .recording { shared.area = LastRecordingArea.load() }
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
        if mode == .recording, case let .area(_, rect) = target { LastRecordingArea.save(rect) }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        continuation?.resume(returning: target)
        continuation = nil
    }
}

/// The area last recorded, offered again by the next recording.
@MainActor
enum LastRecordingArea {
    /// The saved area, if it's still on a connected display.
    static func load() -> CGRect? {
        guard let string = UserDefaults.standard.string(forKey: RecordingOptions.lastAreaKey) else { return nil }
        let rect = NSRectFromString(string)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) else { return nil }
        let visible = rect.intersection(screen.frame)
        return visible.width >= 4 && visible.height >= 4 ? visible.integral : nil
    }

    static func save(_ rect: CGRect) {
        UserDefaults.standard.set(NSStringFromRect(rect), forKey: RecordingOptions.lastAreaKey)
    }
}

/// State shared by the overlays on every display, so window mode and
/// hovering stay in sync across them.
@MainActor
private final class SelectionState {
    let mode: CaptureSelector.Mode
    var pickingWindow = false
    var hoveredWindow: (id: CGWindowID, rect: CGRect)?
    /// An area waiting to be confirmed (the last one recorded), in global
    /// coordinates. It can be moved and resized before confirming.
    var area: CGRect?
    var views: [SelectionView] = []

    /// The pending area as a capture target.
    var areaTarget: CaptureTarget? {
        guard let area,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) })
        else { return nil }
        return .area(screen.displayID ?? 0, area.integral)
    }

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
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    private enum Adjustment { case move, resize(Edges) }

    private let targetScreen: NSScreen
    private let state: SelectionState
    private let onFinish: (CaptureTarget?) -> Void
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    /// Moving or resizing the pending area.
    private var adjusting: (kind: Adjustment, start: CGPoint, original: CGRect)?
    private var adjusted = false

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

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

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

    /// The pending area, if it's on this display, in view coordinates.
    private var localArea: CGRect? {
        guard let area = state.area else { return nil }
        let local = area.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        return local.intersects(bounds) ? local : nil
    }

    /// Which edges of `rect` the point is on, give or take a few points.
    private func edges(at point: CGPoint, of rect: CGRect) -> Edges {
        let tolerance: CGFloat = 6
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return [] }
        var edges: Edges = []
        if abs(point.x - rect.minX) <= tolerance {
            edges.insert(.left)
        } else if abs(point.x - rect.maxX) <= tolerance {
            edges.insert(.right)
        }
        if abs(point.y - rect.minY) <= tolerance {
            edges.insert(.bottom)
        } else if abs(point.y - rect.maxY) <= tolerance {
            edges.insert(.top)
        }
        return edges
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard !state.pickingWindow, let area = localArea else { return .crosshair }
        let edges = edges(at: point, of: area)
        if edges == .left || edges == .right { return .resizeLeftRight }
        if edges == .top || edges == .bottom { return .resizeUpDown }
        if !edges.isEmpty { return .crosshair }
        return area.contains(point) ? .openHand : .crosshair
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor(at: point).set()
        guard state.pickingWindow else { return }
        let hovered = state.windowAt(global(point))
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
        let point = convert(event.locationInWindow, from: nil)
        adjusted = false
        if let area = localArea {
            let edges = edges(at: point, of: area)
            if !edges.isEmpty {
                adjusting = (.resize(edges), point, area)
                return
            }
            if area.contains(point) {
                adjusting = (.move, point, area)
                NSCursor.closedHand.set()
                return
            }
        }
        // Starting a new selection drops the pending area.
        if state.area != nil {
            state.area = nil
            state.redraw()
        }
        dragStart = point
        dragCurrent = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let adjusting {
            adjust(adjusting, to: point)
            return
        }
        guard dragStart != nil else { return }
        dragCurrent = CGPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
        needsDisplay = true
    }

    private func adjust(_ adjusting: (kind: Adjustment, start: CGPoint, original: CGRect), to point: CGPoint) {
        let dx = point.x - adjusting.start.x
        let dy = point.y - adjusting.start.y
        if abs(dx) > 2 || abs(dy) > 2 { adjusted = true }
        guard adjusted else { return }
        let original = adjusting.original
        let minimum: CGFloat = 20
        var rect = original
        switch adjusting.kind {
        case .move:
            rect.origin.x = min(max(original.minX + dx, 0), max(bounds.width - original.width, 0))
            rect.origin.y = min(max(original.minY + dy, 0), max(bounds.height - original.height, 0))
            NSCursor.closedHand.set()
        case let .resize(edges):
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if edges.contains(.left) { minX = min(max(original.minX + dx, 0), maxX - minimum) }
            if edges.contains(.right) { maxX = max(min(original.maxX + dx, bounds.width), minX + minimum) }
            if edges.contains(.bottom) { minY = min(max(original.minY + dy, 0), maxY - minimum) }
            if edges.contains(.top) { maxY = max(min(original.maxY + dy, bounds.height), minY + minimum) }
            rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        state.area = rect.offsetBy(dx: targetScreen.frame.minX, dy: targetScreen.frame.minY)
        state.redraw()
    }

    override func mouseUp(with event: NSEvent) {
        if let adjusting {
            self.adjusting = nil
            let wasAdjusted = adjusted
            adjusted = false
            cursor(at: convert(event.locationInWindow, from: nil)).set()
            // A click inside the pending area, without dragging, takes it.
            if !wasAdjusted, case .move = adjusting.kind, let target = state.areaTarget {
                onFinish(target)
            }
            return
        }
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
            if !state.pickingWindow, let target = state.areaTarget {
                onFinish(target)
            } else {
                onFinish(.display((NSScreen.underMouse ?? targetScreen).displayID ?? 0))
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        var highlight: CGRect?
        var pending = false
        if state.pickingWindow {
            highlight = state.hoveredWindow?.rect.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        } else if let selection {
            highlight = selection
        } else if let localArea {
            highlight = localArea
            pending = true
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
            if pending {
                drawHandles(for: highlight)
                drawPendingHint(for: highlight)
            }
        } else {
            drawHint()
        }
    }

    private func drawHandles(for rect: CGRect) {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        for point in points {
            let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1
            NSColor.black.withAlphaComponent(0.35).setStroke()
            dot.stroke()
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

    /// Explains the pending area just above it (inside its top when there's
    /// no room above).
    private func drawPendingHint(for rect: CGRect) {
        let hint = "Return or click inside to record this area · Drag it or its edges to adjust · Click outside for the full screen"
        let attributes = Self.hintAttributes(size: 13)
        let size = (hint as NSString).size(withAttributes: attributes)
        var center = CGPoint(x: rect.midX, y: rect.maxY + 14 + size.height / 2)
        if center.y + size.height / 2 + 12 > bounds.maxY { center.y = rect.maxY - 20 - size.height / 2 }
        center.x = min(max(center.x, size.width / 2 + 20), bounds.maxX - size.width / 2 - 20)
        drawPill(hint, attributes: attributes, center: center)
    }

    private func drawHint() {
        guard targetScreen == NSScreen.underMouse else { return }
        let hint: String = switch state.mode {
        case .screenshot: "Drag to capture an area · Space for a window · Esc to cancel"
        case .recording: "Drag to record an area · Space for a window · Click or Return for the full screen · Esc to cancel"
        }
        drawPill(hint, attributes: Self.hintAttributes(size: 14), center: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private static func hintAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white]
    }

    private func drawPill(_ hint: String, attributes: [NSAttributedString.Key: Any], center: CGPoint) {
        let text = hint as NSString
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let background = CGRect(x: origin.x - 14, y: origin.y - 8, width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: background, xRadius: 10, yRadius: 10).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}
