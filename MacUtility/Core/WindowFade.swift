import AppKit

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
