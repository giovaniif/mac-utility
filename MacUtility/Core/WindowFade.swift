import AppKit
import SwiftUI

extension NSWindow {
    /// Orders the window in and fades it up, optionally rising a few points.
    func fadeIn(duration: TimeInterval = 0.18, rise: CGFloat = 0, makeKey: Bool = false) {
        let target = frame
        if !isVisible || alphaValue < 1 {
            alphaValue = 0
            if rise != 0 { setFrame(target.offsetBy(dx: 0, dy: -rise), display: false) }
        }
        if makeKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            if rise != 0 { animator().setFrame(target, display: true) }
        }
    }

    /// Fades the window out, then orders it out unless it was shown again meanwhile.
    func fadeOut(duration: TimeInterval = 0.15) {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        }
    }
}

extension NSView {
    /// Plain container hosting SwiftUI, for panels whose frame we set
    /// ourselves. As a window's content view, NSHostingView keeps updating the
    /// window's size limits and transform from SwiftUI, which can fight our
    /// frames until AppKit throws ("more Update Constraints in Window passes
    /// than there are views"). Inside a container it just fills it.
    static func hosting<Content: View>(_ rootView: Content) -> NSView {
        container(for: NSHostingView(rootView: rootView))
    }

    static func container(for hosting: NSView) -> NSView {
        let container = NSView(frame: hosting.frame)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }
}
