import AppKit
import ScreenCaptureKit

/// Set switches crossfade: a still of the stage covers the display while the
/// real windows move underneath, then fades out. The same still gives the
/// switcher and shelf their window thumbnails.
@MainActor
final class StageMotion {
    private var overlay: NSPanel?
    private var filter: (filter: SCContentFilter, displayID: CGDirectDisplayID, at: Date)?

    func crossfade(on screen: NSScreen, capturing windows: [WindowID: CGRect], then change: @escaping ([WindowID: NSImage]) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            change([:])
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task {
            guard let image = await capture(screen) else {
                change([:])
                return
            }
            let shots = crops(of: image, screen: screen, windows: windows)
            guard !reduceMotion else {
                change(shots)
                return
            }
            let overlay = showOverlay(image, on: screen)
            change(shots)
            // Let the apps redraw at their new frames before revealing them.
            try? await Task.sleep(for: .milliseconds(50))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlay.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { overlay.orderOut(nil) }
            }
        }
    }

    private func capture(_ screen: NSScreen) async -> CGImage? {
        guard let displayID = screen.displayID else { return nil }
        do {
            let filter = try await contentFilter(for: displayID)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }

    /// The display minus our own panels. Shareable content is slow to list,
    /// so the filter is kept for a minute.
    private func contentFilter(for displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        if let filter, filter.displayID == displayID, Date().timeIntervalSince(filter.at) < 60 {
            return filter.filter
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let made = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        filter = (made, displayID, Date())
        return made
    }

    private func crops(of image: CGImage, screen: NSScreen, windows: [WindowID: CGRect]) -> [WindowID: NSImage] {
        let scale = CGFloat(image.width) / screen.frame.width
        var shots: [WindowID: NSImage] = [:]
        for (id, rect) in windows {
            let pixels = CGRect(
                x: (rect.minX - screen.frame.minX) * scale,
                y: (screen.frame.maxY - rect.maxY) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral
            if let cropped = image.cropping(to: pixels) {
                shots[id] = NSImage(cgImage: cropped, size: rect.size)
            }
        }
        return shots
    }

    private func showOverlay(_ image: CGImage, on screen: NSScreen) -> NSPanel {
        let panel = overlay ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = NSImageView(image: NSImage(cgImage: image, size: screen.frame.size))
        view.imageScaling = .scaleAxesIndependently
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        overlay = panel
        return panel
    }
}
