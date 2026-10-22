import AppKit
import ApplicationServices
import os

/// Moves the frontmost app's focused window to the adjacent display via the
/// Accessibility API.
@MainActor
final class WindowMover {
    private let permissions: Permissions
    private let log = Logger(subsystem: "com.giovani.MacUtility", category: "windows")

    init(permissions: Permissions) {
        self.permissions = permissions
    }

    func move(_ direction: DisplayDirection) {
        permissions.refresh()
        guard permissions.accessibility else {
            permissions.requestAccessibility()
            return
        }
        let screens = NSScreen.screens
        guard screens.count > 1, let primary = screens.first else {
            HUD.show("Only one display")
            return
        }
        guard let window = focusedWindow() else {
            HUD.show("No window to move")
            return
        }
        if window.bool("AXFullScreen") == true {
            HUD.show("Can't move a full-screen window")
            return
        }
        guard let position = window.point(kAXPositionAttribute), let size = window.size(kAXSizeAttribute) else {
            log.error("focused window has no position or size")
            return
        }

        let primaryHeight = primary.frame.height
        let frame = ScreenGeometry.flip(CGRect(origin: position, size: size), primaryHeight: primaryHeight)
        let frames = screens.map(\.frame)
        let order = ScreenGeometry.ordered(frames)
        guard let current = ScreenGeometry.screenIndex(for: frame, in: frames),
              let slot = order.firstIndex(of: current) else {
            return
        }
        let step = direction == .next ? 1 : -1
        let target = order[(slot + step + order.count) % order.count]

        let moved = ScreenGeometry.center(frame, in: screens[target].visibleFrame)
        let axFrame = ScreenGeometry.flip(moved, primaryHeight: primaryHeight)

        // Size, position, size: some apps clamp size to the screen they're on.
        window.set(kAXSizeAttribute, size: axFrame.size)
        window.set(kAXPositionAttribute, point: axFrame.origin)
        window.set(kAXSizeAttribute, size: axFrame.size)
    }

    private func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}

private extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    func bool(_ attribute: String) -> Bool? {
        value(attribute) as? Bool
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let raw = value(attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    func size(_ attribute: String) -> CGSize? {
        guard let raw = value(attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    func set(_ attribute: String, point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(self, attribute as CFString, value)
        }
    }

    func set(_ attribute: String, size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(self, attribute as CFString, value)
        }
    }
}
