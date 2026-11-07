import AppKit
import Observation
import os

private let trayLog = Logger(subsystem: "com.giovani.MacUtility", category: "focus")

/// Focus's own menu bar item, next to Mac Utility's: the numbers of the sets
/// with windows, the current one filled (outlined when it's empty). Click a
/// number to go to that set; click beside the numbers for the switcher.
@MainActor
final class SetsStatusItem: NSObject {
    private unowned let controller: FocusController
    private var item: NSStatusItem?
    private var numbers: [Int] = []

    static let cell: CGFloat = 17
    static let spacing: CGFloat = 3
    static let inset: CGFloat = 4

    init(controller: FocusController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.toolTip = "Focus sets"
            self.item = item
        }
        track()
    }

    func hide() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Redraws now and again whenever the sets change.
    private func track() {
        guard item != nil else { return }
        withObservationTracking { [weak self] in
            guard let self else { return }
            self.render(occupied: self.controller.state.occupied, current: self.controller.state.current)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func render(occupied: [Int], current: Int) {
        numbers = Array(Set(occupied + [current])).sorted()
        let image = Self.image(numbers: numbers, current: current, occupied: Set(occupied))
        item?.button?.image = image
        item?.button?.imagePosition = .imageOnly
        item?.button?.setAccessibilityLabel("Focus, set \(current). Sets with windows: \(occupied.map(String.init).joined(separator: ", "))")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, let window = sender.window else { return }
        // The event's own window coordinates don't belong to the button's
        // window on recent macOS, so take the pointer's screen position.
        let point = sender.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let imageWidth = sender.image?.size.width ?? 0
        let x = point.x - (sender.bounds.width - imageWidth) / 2 - Self.inset
        let index = Int(floor(x / (Self.cell + Self.spacing)))
        trayLog.debug("tray click type \(event.type.rawValue) x \(Int(point.x)) bounds \(Int(sender.bounds.width)) image \(Int(imageWidth)) col \(Int(x)) index \(index) numbers \(self.numbers)")
        if event.type == .leftMouseUp, x >= 0, numbers.indices.contains(index) {
            controller.goTo(numbers[index])
        } else {
            controller.showSwitcher()
        }
    }

    #if DEBUG
    /// Clicks the number at `index` with a real mouse event, as a user would.
    func debugClick(index: Int) {
        guard let button = item?.button, let window = button.window, let screen = NSScreen.screens.first else { return }
        let imageWidth = button.image?.size.width ?? 0
        let x = (button.bounds.width - imageWidth) / 2 + Self.inset + CGFloat(index) * (Self.cell + Self.spacing) + Self.cell / 2
        let local = CGPoint(x: x, y: button.bounds.midY)
        let onScreen = window.convertPoint(toScreen: button.convert(local, to: nil))
        let point = CGPoint(x: onScreen.x, y: screen.frame.height - onScreen.y)
        trayLog.debug("tray debug click at \(Int(point.x)),\(Int(point.y)) window \(window.frame.debugDescription, privacy: .public)")
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
    #endif

    /// Template image, so it follows the menu bar's light or dark look.
    static func image(numbers: [Int], current: Int, occupied: Set<Int>) -> NSImage {
        let width = inset * 2 + CGFloat(max(numbers.count, 1)) * (cell + spacing) - spacing
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            for (index, number) in numbers.enumerated() {
                let rect = CGRect(x: inset + CGFloat(index) * (cell + spacing), y: 1, width: cell, height: 16)
                let text = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: NSColor.black])
                let size = text.size()
                let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                if number == current, occupied.contains(number) {
                    NSColor.black.setFill()
                    shape.fill()
                    // Knock the digit out of the filled square.
                    NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                    text.draw(at: point)
                    NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
                } else if number == current {
                    // On an empty set: outlined, so you still see where you are.
                    NSColor.black.setStroke()
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
                    outline.lineWidth = 1.5
                    outline.stroke()
                    text.draw(at: point)
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
