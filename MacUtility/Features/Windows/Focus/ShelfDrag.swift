import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ShelfDragModel {
    var thumbnail: NSImage?
    var icon: NSImage?
    var appName = ""
    var drop: StageDrop?
    var targetName = ""
}

/// Dragging a window out of a shelf card onto the stage. A small picture of
/// the window follows the pointer; the spot it would land on is outlined.
/// Dropping on a window trades places with it, on a lone window's side puts
/// it beside, on an empty set moves it there. Esc or a drop elsewhere cancels.
@MainActor
final class ShelfDrag {
    private unowned let controller: FocusController
    private let model = ShelfDragModel()
    private let ghost = ShelfDrag.overlay(level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1))
    private let target = ShelfDrag.overlay(level: .floating)
    private let keys = KeyMonitor()
    private static let ghostSize = CGSize(width: 180, height: 120)

    /// The window being dragged; nil when no drag is on, or it was cancelled.
    private(set) var window: WindowID?
    private var cancelled = false

    init(controller: FocusController) {
        self.controller = controller
        ghost.contentView = NSView.hosting(ShelfDragGhost(model: model))
        target.contentView = NSView.hosting(ShelfDropTarget(model: model))
    }

    var isDragging: Bool { window != nil || cancelled }

    /// The pointer moved with `id` in hand. `overShelf` says it's still
    /// over the shelf, where nothing happens.
    func move(_ id: WindowID, overShelf: Bool) {
        if cancelled { return }
        if window == nil { begin(id) }
        let point = NSEvent.mouseLocation
        ghost.setFrameOrigin(CGPoint(x: point.x - Self.ghostSize.width / 2, y: point.y - Self.ghostSize.height / 2))
        let drop = overShelf ? nil : controller.shelfDrop(at: point)
        guard drop != model.drop else { return }
        model.drop = drop
        if let drop {
            if case let .swap(other, _) = drop { model.targetName = controller.summary(of: other).appName }
            target.setFrame(controller.cocoa(drop.rect), display: true)
            target.orderFrontRegardless()
        } else {
            target.orderOut(nil)
        }
    }

    /// The button came up. Returns true when the window was dropped somewhere.
    @discardableResult
    func end() -> Bool {
        defer { reset() }
        guard !cancelled, let window, let drop = model.drop else { return false }
        controller.drop(window, drop)
        return true
    }

    private func begin(_ id: WindowID) {
        let summary = controller.summary(of: id)
        window = id
        model.thumbnail = controller.thumbnails[id]
        model.icon = summary.icon
        model.appName = summary.appName
        model.drop = nil
        ghost.setContentSize(Self.ghostSize)
        ghost.orderFrontRegardless()
        keys.start { [weak self] code, _, _ in
            guard code == KeyCode.escape, let self else { return false }
            self.cancel()
            return true
        }
    }

    private func cancel() {
        cancelled = true
        window = nil
        hideOverlays()
    }

    private func reset() {
        window = nil
        cancelled = false
        model.drop = nil
        hideOverlays()
    }

    private func hideOverlays() {
        keys.stop()
        ghost.orderOut(nil)
        target.orderOut(nil)
    }

    /// Click-through panel that never takes focus.
    private static func overlay(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        return panel
    }
}

/// The window in hand: its last snapshot, or its app icon.
private struct ShelfDragGhost: View {
    let model: ShelfDragModel

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image = model.thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let icon = model.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        .opacity(0.9)
        .padding(6)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

/// Where the window would land: the window it would replace, dimmed and
/// outlined, or the empty pane or stage it would take.
private struct ShelfDropTarget: View {
    let model: ShelfDragModel

    private var replacing: Bool {
        if case .swap = model.drop { return true }
        return false
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(replacing ? Color.black.opacity(0.45) : Color.accentColor.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: replacing ? [] : [8, 6]))
            )
            .overlay {
                Text(label)
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.panelFill, in: Capsule())
            }
            .environment(\.colorScheme, .dark)
    }

    private var label: String {
        switch model.drop {
        case .swap: "Swap \(model.appName) with \(model.targetName)"
        case .beside(true, _): "Put \(model.appName) on the left"
        case .beside(false, _): "Put \(model.appName) on the right"
        case .open: "Move \(model.appName) here"
        case nil: ""
        }
    }
}
