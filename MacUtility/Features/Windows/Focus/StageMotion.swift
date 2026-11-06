import AppKit
import ScreenCaptureKit
import os

private let motionLog = Logger(subsystem: "com.giovani.MacUtility", category: "focus")

/// Set switches slide like Spaces. A still of the old stage covers the
/// display while the real windows move underneath; a picture of the new
/// stage, built from captures of its own windows laid over the wallpaper,
/// slides in from the side as the old one slides out. The menu bar stays put.
///
/// The new stage isn't captured from the screen: right after the windows
/// move, the screen still shows the old ones for a while, so a capture would
/// slide the old stage in and leave it lingering when the cover lifts.
@MainActor
final class StageMotion {
    private var overlay: NSPanel?
    private var filter: (filter: SCContentFilter, displayID: CGDirectDisplayID, at: Date)?
    private var content: (content: SCShareableContent, at: Date)?
    private var wallpaper: (image: CGImage, displayID: CGDirectDisplayID, at: Date)?

    /// Starts listing windows ahead of a switch (on the leader key), so the
    /// switch itself doesn't wait for it.
    func prefetch() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task { _ = await shareableContent() }
    }

    /// A window that moves to the new set with you: it travels from `from`
    /// to `to` above both stages instead of sliding with either.
    struct Carried {
        let id: WindowID
        let from: CGRect
        let to: CGRect
    }

    /// `outgoing` are the visible windows now (Cocoa frames), for card
    /// thumbnails; `incoming` the new set's windows at their target frames,
    /// back to front; `carried` windows going along (leader ⇧1–9).
    func slide(
        on screen: NSScreen,
        forward: Bool,
        outgoing: [WindowID: CGRect],
        incoming: [(id: WindowID, frame: CGRect)],
        carried: [Carried] = [],
        then change: @escaping ([WindowID: NSImage]) -> Void
    ) {
        // A switch while the last one is still moving: the cover is up already.
        if let overlay, overlay.isVisible {
            change([:])
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            change([:])
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let carriedIDs = Set(carried.map(\.id))
        // Carrying a window means the old stage is drawn without it, so it's
        // built from window captures too, rather than taken from the screen.
        let staying = outgoing.filter { !carriedIDs.contains($0.key) }.map { (id: $0.key, frame: $0.value) }
        let captureIDs = incoming.map(\.id) + carried.map(\.id) + (carried.isEmpty ? [] : staying.map(\.id))
        Task {
            // Main-actor tasks, so the captures overlap while they wait.
            let windowShots = Task { await self.windowImages(captureIDs) }
            let wallpaperShot = Task { await self.wallpaperImage(for: screen) }
            let area = stageArea(of: screen)
            var thumbnails: [WindowID: NSImage] = [:]
            let oldStage: CALayer
            if carried.isEmpty {
                guard let before = await capture(screen) else {
                    change([:])
                    return
                }
                thumbnails = crops(of: before, screen: screen, windows: outgoing).mapValues { Self.thumbnail($0) }
                oldStage = CALayer()
                oldStage.frame = CGRect(origin: .zero, size: area.size)
                oldStage.contents = stage(of: before, screen: screen)
                oldStage.contentsGravity = .resize
            } else {
                let images = await windowShots.value
                oldStage = stageLayer(area: area, screen: screen, wallpaper: await wallpaperShot.value, windows: staying, images: images)
            }
            guard !reduceMotion else {
                change(thumbnails)
                return
            }
            let images = await windowShots.value
            let backdrop = await wallpaperShot.value
            // The carried window sits above the old stage from the start,
            // where it is now, so nothing changes on screen when the cover goes up.
            let travellers = carried.compactMap { item -> (CALayer, Carried)? in
                guard let image = images[item.id] else { return nil }
                return (windowLayer(image, frame: item.from.offsetBy(dx: -area.minX, dy: -area.minY)), item)
            }
            let newStage = stageLayer(
                area: area, screen: screen, wallpaper: backdrop,
                windows: incoming.filter { !carriedIDs.contains($0.id) }, images: images
            )
            let overlay = showOverlay(oldStage, above: travellers.map(\.0), area: area)
            // Start the slide before any window moves. The animation runs in
            // the window server, so the Accessibility calls that move windows
            // (they block the main thread for 50–150 ms) can't stall it, and
            // the windows settle under the cover while it plays.
            run(overlay, old: oldStage, new: newStage, travellers: travellers.map { ($0.0, $0.1.to.offsetBy(dx: -area.minX, dy: -area.minY)) }, width: area.width, forward: forward)
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(16))
            for (id, image) in images { thumbnails[id] = Self.thumbnail(image) }
            change(thumbnails)
        }
    }

    /// The display below the menu bar, in Cocoa coordinates.
    private func stageArea(of screen: NSScreen) -> CGRect {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: screen.frame.height - menuBar)
    }

    /// The part of a display capture below the menu bar.
    private func stage(of image: CGImage, screen: NSScreen) -> CGImage? {
        let scale = CGFloat(image.width) / screen.frame.width
        let menuBar = (screen.frame.maxY - screen.visibleFrame.maxY) * scale
        return image.cropping(to: CGRect(x: 0, y: menuBar, width: CGFloat(image.width), height: CGFloat(image.height) - menuBar).integral)
    }

    /// The new stage as layers: wallpaper, then each window where it's going,
    /// with a shadow like the real one.
    private func stageLayer(area: CGRect, screen: NSScreen, wallpaper: CGImage?, windows: [(id: WindowID, frame: CGRect)], images: [WindowID: CGImage]) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: area.size)
        root.backgroundColor = NSColor.black.cgColor
        if let wallpaper {
            let backdrop = CALayer()
            // The wallpaper covers the whole display; the menu bar strip is cut off.
            backdrop.frame = CGRect(x: screen.frame.minX - area.minX, y: screen.frame.minY - area.minY, width: screen.frame.width, height: screen.frame.height)
            backdrop.contents = wallpaper
            backdrop.contentsGravity = .resizeAspectFill
            root.addSublayer(backdrop)
        }
        for window in windows {
            guard let image = images[window.id] else { continue }
            root.addSublayer(windowLayer(image, frame: window.frame.offsetBy(dx: -area.minX, dy: -area.minY)))
        }
        return root
    }

    /// A captured window with a shadow like the real one.
    private func windowLayer(_ image: CGImage, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsGravity = .resize
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: -10)
        return layer
    }

    private static let duration = 0.38
    // Eases in and lands softly, close to a Spaces swipe.
    private static let timing = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.15, 1)

    private func run(_ overlay: NSPanel, old: CALayer, new: CALayer, travellers: [(CALayer, CGRect)], width: CGFloat, forward: Bool) {
        guard let root = overlay.contentView?.layer else {
            fadeOut(overlay)
            return
        }
        let shift = forward ? width : -width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        new.position.x += shift
        // Below the travellers, above the old stage.
        root.insertSublayer(new, above: old)
        CATransaction.commit()

        // Explicit animations: AppKit turns implicit ones off for layers
        // inside a view, so changing a property alone would just jump.
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                overlay.orderOut(nil)
                root.sublayers?.forEach { $0.removeFromSuperlayer() }
            }
        }
        for layer in [old, new] {
            animate(layer, "position.x", from: layer.position.x, to: layer.position.x - shift)
            layer.position.x -= shift
        }
        for (layer, target) in travellers {
            let center = CGPoint(x: target.midX, y: target.midY)
            animate(layer, "position", from: NSValue(point: layer.position), to: NSValue(point: center))
            animate(layer, "bounds.size", from: NSValue(size: layer.bounds.size), to: NSValue(size: target.size))
            layer.position = center
            layer.bounds.size = target.size
        }
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, _ keyPath: String, from: Any, to: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.duration
        animation.timingFunction = Self.timing
        layer.add(animation, forKey: keyPath)
    }

    private func fadeOut(_ overlay: NSPanel) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                overlay.orderOut(nil)
                overlay.alphaValue = 1
            }
        }
    }

    // MARK: Captures

    /// Window listing is slow (tens of ms), so it's kept for a few seconds.
    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(content.at) < 3 { return content.content }
        guard let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        content = (fresh, Date())
        return fresh
    }

    /// Full-resolution captures of single windows, wherever they are (parked
    /// ones included), without their shadows.
    private func windowImages(_ ids: [WindowID]) async -> [WindowID: CGImage] {
        guard !ids.isEmpty, var listed = await shareableContent() else { return [:] }
        if ids.contains(where: { id in !listed.windows.contains { $0.windowID == id } }) {
            // A window newer than the cached list: list again.
            content = nil
            guard let fresh = await shareableContent() else { return [:] }
            listed = fresh
        }
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        // All at once: each capture mostly waits on the window server.
        let captures = ids.compactMap { id -> (WindowID, Task<CGImage?, Never>)? in
            guard let window = listed.windows.first(where: { $0.windowID == id }), window.frame.width > 0 else { return nil }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return (id, Task { try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) })
        }
        var images: [WindowID: CGImage] = [:]
        for (id, capture) in captures {
            if let image = await capture.value { images[id] = image }
        }
        return images
    }

    /// The desktop picture alone: the display's windows below normal level.
    /// Kept for five minutes.
    private func wallpaperImage(for screen: NSScreen) async -> CGImage? {
        guard let displayID = screen.displayID else { return nil }
        if let wallpaper, wallpaper.displayID == displayID, Date().timeIntervalSince(wallpaper.at) < 300 { return wallpaper.image }
        guard let listed = await shareableContent(),
              let display = listed.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let desktop = listed.windows.filter { $0.windowLayer < 0 && $0.frame.intersects(display.frame) }
        guard !desktop.isEmpty else { return nil }
        // 1× is plenty: it's only on screen while it slides, and it's cached.
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width)
        config.height = Int(screen.frame.height)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: desktop), configuration: config) else { return nil }
        wallpaper = (image, displayID, Date())
        return image
    }

    /// Captures each window on its own, wherever it is, small enough for a
    /// card. Calls `deliver` as each one arrives so cards fill in one by one.
    func snapshots(of ids: [WindowID], deliver: @escaping (WindowID, NSImage) -> Void) {
        guard CGPreflightScreenCaptureAccess(), !ids.isEmpty else { return }
        Task {
            guard let listed = await shareableContent() else { return }
            let windows = Dictionary(listed.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
            for id in ids {
                guard let window = windows[id], window.frame.width > 0, window.frame.height > 0 else { continue }
                let config = SCStreamConfiguration()
                let width = min(window.frame.width, 320)
                config.width = Int(width * scale)
                config.height = Int(width * window.frame.height / window.frame.width * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
                deliver(id, Self.thumbnail(image))
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
            motionLog.error("capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The display minus our own panels. Kept for a minute.
    private func contentFilter(for displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        if let filter, filter.displayID == displayID, Date().timeIntervalSince(filter.at) < 60 {
            return filter.filter
        }
        guard let listed = await shareableContent(),
              let display = listed.displays.first(where: { $0.displayID == displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let own = listed.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let made = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        filter = (made, displayID, Date())
        return made
    }

    /// A small copy for cards. Crops and full captures would otherwise keep
    /// whole Retina screenshots (about 25 MB each) alive in memory.
    static func thumbnail(_ image: CGImage, maxWidth: Int = 600) -> NSImage {
        let width = min(image.width, maxWidth)
        let height = max(1, image.height * width / max(image.width, 1))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return NSImage(cgImage: image, size: .zero) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return NSImage(cgImage: image, size: .zero) }
        return NSImage(cgImage: small, size: CGSize(width: width / 2, height: height / 2))
    }

    private func crops(of image: CGImage, screen: NSScreen, windows: [WindowID: CGRect]) -> [WindowID: CGImage] {
        let scale = CGFloat(image.width) / screen.frame.width
        var shots: [WindowID: CGImage] = [:]
        for (id, rect) in windows {
            let pixels = CGRect(
                x: (rect.minX - screen.frame.minX) * scale,
                y: (screen.frame.maxY - rect.maxY) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral
            if let cropped = image.cropping(to: pixels) { shots[id] = cropped }
        }
        return shots
    }

    private func showOverlay(_ base: CALayer, above: [CALayer], area: CGRect) -> NSPanel {
        let panel = overlay ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = panel.contentView ?? NSView()
        view.wantsLayer = true
        panel.contentView = view
        panel.setFrame(area, display: false)
        // Layer contents go straight to the window server, no redraw pass.
        let root = view.layer!
        root.masksToBounds = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.addSublayer(base)
        above.forEach(root.addSublayer)
        CATransaction.commit()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.display()
        overlay = panel
        return panel
    }
}
