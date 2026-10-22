import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CleaningCountdown {
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

/// Borderless full-screen window on every display. The Unlock button is the
/// way out while the keyboard is blocked.
@MainActor
final class CleaningOverlay {
    private var windows: [NSWindow] = []
    private let countdown = CleaningCountdown(remaining: 0)

    func show(seconds: Int, onUnlock: @escaping @MainActor () -> Void) {
        hide()
        countdown.remaining = seconds
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.contentView = NSView.hosting(
                CleaningOverlayView(countdown: countdown, onUnlock: onUnlock)
            )
            window.setFrame(screen.frame, display: true)
            window.fadeIn(duration: 0.25)
            windows.append(window)
        }
        NSApp.activate()
    }

    func update(remaining: Int) {
        countdown.remaining = remaining
    }

    func hide() {
        windows.forEach { $0.fadeOut(duration: 0.25) }
        windows.removeAll()
    }
}

private struct CleaningOverlayView: View {
    let countdown: CleaningCountdown
    let onUnlock: @MainActor () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 24) {
                Image(systemName: "keyboard")
                    .font(.system(size: 64))
                Text("Keyboard locked for cleaning")
                    .font(.largeTitle.bold())
                Text("Unlocks automatically in \(countdown.remaining)s")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Text("Keyboard lock")
                        .font(.title2)
                    Toggle("Keyboard lock", isOn: Binding(
                        get: { true },
                        set: { if !$0 { onUnlock() } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .scaleEffect(1.6)
                }
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }
}
