import AppKit
import ScreenCaptureKit
import os

private let motionLog = Logger(subsystem: "com.giovani.MacUtility", category: "focus")

/// How a set switch looks.
enum SwitchAnimation: String, CaseIterable {
    /// The old stage stays frozen on screen while the windows move, then fades out.
    case fade
    /// Windows just move.
    case none

    static var current: SwitchAnimation {
        UserDefaults.standard.string(forKey: "focus.animation").flatMap(SwitchAnimation.init) ?? .fade
    }
}

/// Set switches, kept as simple as possible: freeze the screen as it is, move
/// the real windows underneath, give the apps a moment to redraw, then fade
/// the frozen picture out. Nothing on screen is ever a picture of where a
/// window is going, so nothing can disagree with the real screen when the
/// picture goes away. (A Spaces-style slide was tried first; every way of
/// faking the incoming stage left a visible snap or flick at the end.)
@MainActor
final class StageMotion {
    private var overlay: NSPanel?
    private var filter: (filter: SCContentFilter, displayID: CGDirectDisplayID, at: Date)?
    private var content: (content: SCShareableContent, at: Date)?

    /// Starts listing windows ahead of a switch (on the leader key), so the
    /// switch itself doesn't wait for it.
    func prefetch() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task { _ = await shareableContent() }
    }

    /// Runs `change` (which moves the windows) behind the switch animation.
    /// `outgoing` are the visible windows now (Cocoa frames); the frozen
    /// picture also gives their cards a thumbnail.
    func transition(on screen: NSScreen, outgoing: [WindowID: CGRect], then change: @escaping ([WindowID: NSImage]) -> Void) {
        // A switch while the last one is still fading: just move the windows.
        if let overlay, overlay.isVisible {
            change([:])
            return
        }
        guard SwitchAnimation.current == .fade, CGPreflightScreenCaptureAccess(),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            change([:])
            return
        }
        Task {
            guard let before = await capture(screen) else {
                change([:])
                return
            }
            let thumbnails = crops(of: before, screen: screen, windows: outgoing).mapValues { Self.thumbnail($0) }
            let overlay = showOverlay(before, on: screen)
            // The picture has to be on screen before any window moves.
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(16))
            change(thumbnails)
            // Let the apps redraw at their new place before revealing them.
            try? await Task.sleep(for: .milliseconds(80))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlay.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    overlay.orderOut(nil)
                    overlay.alphaValue = 1
                }
            }
        }
    }

    #if DEBUG
    /// Shows the frozen picture for a few seconds without moving anything.
    func debugFreeze(on screen: NSScreen) {
        Task {
            guard let before = await capture(screen) else { return }
            let overlay = showOverlay(before, on: screen)
            motionLog.notice("freeze: panel \(overlay.frame.debugDescription), view \(overlay.contentView?.frame.debugDescription ?? "-"), layer \(overlay.contentView?.layer?.bounds.debugDescription ?? "-") scale \(overlay.contentView?.layer?.contentsScale ?? 0) gravity \(overlay.contentView?.layer?.contentsGravity.rawValue ?? "-") image \(before.width)x\(before.height) screen \(screen.frame.debugDescription) visible \(screen.visibleFrame.debugDescription)")
            try? await Task.sleep(for: .seconds(3))
            overlay.orderOut(nil)
        }
    }
    #endif

    /// The part of the display below the menu bar, so the menu bar stays live.
    private func showOverlay(_ image: CGImage, on screen: NSScreen) -> NSPanel {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let area = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: screen.frame.height - menuBar)
        let scale = CGFloat(image.width) / screen.frame.width
        let below = image.cropping(to: CGRect(x: 0, y: menuBar * scale, width: CGFloat(image.width), height: CGFloat(image.height) - menuBar * scale).integral)

        let panel = overlay ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // No system "pop in" when it appears: it scaled the frozen picture
        // down and back up, which read as the screen shrinking on each switch.
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = panel.contentView ?? NSView()
        view.wantsLayer = true
        panel.contentView = view
        panel.setFrame(area, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contents = below
        view.layer?.contentsGravity = .resize
        CATransaction.commit()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.display()
        overlay = panel
        return panel
    }

    // MARK: Captures

    /// Window listing is slow (tens of ms), so it's kept for a few seconds.
    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(content.at) < 3 { return content.content }
        guard let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        content = (fresh, Date())
        return fresh
    }

    /// Captures each window on its own, wherever it is (parked ones too),
    /// small enough for a card. Calls `deliver` as each one arrives.
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

    /// The whole display, minus Focus's own panels.
    private func capture(_ screen: NSScreen) async -> CGImage? {
        guard let displayID = screen.displayID else { return nil }
        do {
            let filter = try await contentFilter(for: displayID)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            // Keep window shadows, so the frozen picture matches the screen.
            config.ignoreShadowsDisplay = false
            config.capturesShadowsOnly = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            motionLog.error("capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Kept for a minute: listing shareable content is slow.
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
}
