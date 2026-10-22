import AppKit
import AVFoundation
import Observation
import SwiftUI

/// A finished capture shown in the side previews.
struct CaptureResult: Identifiable {
    enum Kind { case screenshot, recording }

    let id = UUID()
    let kind: Kind
    let url: URL
    let thumbnail: NSImage
}

@MainActor
@Observable
final class QuickAccessModel {
    var results: [CaptureResult] = []
    var hovering = false
}

/// CleanShot-style stack of thumbnails in the bottom-left corner after each
/// capture. Drag one into any app, or hover for actions. Each dismisses
/// itself after a while unless the pointer is over the stack.
@MainActor
final class QuickAccessOverlay {
    private let model = QuickAccessModel()
    private let panel: NSPanel
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    private static let lifetime: Duration = .seconds(12)
    private static let width: CGFloat = 240

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = QuickAccessView(model: model) { [weak self] action, result in
            self?.perform(action, on: result)
        }
        panel.contentView = NSHostingView(rootView: view)
    }

    func show(_ result: CaptureResult) {
        model.results.append(result)
        layout()
        panel.orderFrontRegardless()
        scheduleDismiss(result.id)
    }

    /// Hides the stack while a capture is taken, so it doesn't end up in it.
    func setHidden(_ hidden: Bool) {
        if hidden {
            panel.orderOut(nil)
        } else if !model.results.isEmpty {
            panel.orderFrontRegardless()
        }
    }

    private func layout() {
        guard let screen = NSScreen.underMouse else { return }
        let rowHeight: CGFloat = 170
        let height = min(CGFloat(model.results.count) * rowHeight + 20, screen.visibleFrame.height)
        panel.setFrame(
            NSRect(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16, width: Self.width, height: height),
            display: true
        )
    }

    private func scheduleDismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled, let self else { return }
            if self.model.hovering {
                self.scheduleDismiss(id)
            } else {
                self.remove(id)
            }
        }
    }

    private func remove(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        model.results.removeAll { $0.id == id }
        if model.results.isEmpty {
            panel.orderOut(nil)
        } else {
            layout()
        }
    }

    fileprivate enum Action { case open, copy, reveal, trash, close }

    private func perform(_ action: Action, on result: CaptureResult) {
        switch action {
        case .open:
            NSWorkspace.shared.open(result.url)
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if result.kind == .screenshot, let image = NSImage(contentsOf: result.url) {
                pasteboard.writeObjects([image])
            } else {
                pasteboard.writeObjects([result.url as NSURL])
            }
            HUD.show("Copied")
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
        case .trash:
            try? FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
        case .close:
            break
        }
        if action != .reveal, action != .open { remove(result.id) }
    }
}

private struct QuickAccessView: View {
    let model: QuickAccessModel
    let perform: (QuickAccessOverlay.Action, CaptureResult) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            ForEach(model.results) { result in
                QuickAccessCard(result: result) { perform($0, result) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.3), value: model.results.map(\.id))
        .onHover { model.hovering = $0 }
    }
}

private struct QuickAccessCard: View {
    let result: CaptureResult
    let perform: (QuickAccessOverlay.Action) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(nsImage: result.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 220, height: 150)
                .clipped()
            if result.kind == .recording {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
            if hovering {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        button("Copy", "doc.on.doc", .copy)
                        button("Show", "folder", .reveal)
                    }
                    HStack(spacing: 8) {
                        button("Open", "arrow.up.forward.app", .open)
                        button("Trash", "trash", .trash)
                    }
                }
                VStack {
                    HStack {
                        Button { perform(.close) } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)
            }
        }
        .frame(width: 220, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: result.url) ?? NSItemProvider() }
    }

    private func button(_ title: String, _ icon: String, _ action: QuickAccessOverlay.Action) -> some View {
        Button { perform(action) } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(width: 80, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }
}

enum Thumbnails {
    static func forVideo(_ url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
