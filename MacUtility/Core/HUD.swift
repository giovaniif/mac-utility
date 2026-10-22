import AppKit
import SwiftUI

/// Brief, non-interactive message centered on the main screen.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String) {
        let view = Text(message)
            .font(.title3.weight(.medium))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .fixedSize()
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = Self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hosting.frame.size = size
        panel.contentView = NSView.container(for: hosting)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        panel.fadeIn(duration: 0.15)
        Self.panel = panel

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            panel.fadeOut(duration: 0.25)
        }
    }
}
