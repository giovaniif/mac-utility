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
    var thumbnail: NSImage
}

@MainActor
@Observable
final class QuickAccessModel {
    var results: [CaptureResult] = []
}

/// CleanShot-style stack of thumbnails in the bottom-left corner after each
/// capture. They stay until dragged out, copied, saved, trashed or closed.
@MainActor
final class QuickAccessOverlay {
    private let model = QuickAccessModel()
    private let panel: NSPanel
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
        panel.contentView = NSView.hosting(view)
    }

    /// Captures exclude this window instead of hiding it, so the stack
    /// never blinks.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    /// Keeps the stack off screen while recording, then brings it back.
    func setHidden(_ hidden: Bool) {
        if hidden {
            panel.fadeOut()
        } else if !model.results.isEmpty {
            panel.fadeIn(duration: 0.2)
        }
    }

    /// The newest card goes on top. The panel grows upward from a fixed
    /// bottom edge, so the cards already showing don't move.
    func show(_ result: CaptureResult) {
        layout(count: model.results.count + 1)
        if !panel.isVisible { panel.orderFrontRegardless() }
        withAnimation(.easeOut(duration: 0.3)) { model.results.insert(result, at: 0) }
    }

    /// The panel is sized for the stack; cards animate inside it.
    private func layout(count: Int) {
        // Stay on the same display while cards are showing.
        let current = panel.isVisible ? panel.screen : nil
        guard let screen = current ?? NSScreen.underMouse else { return }
        let rowHeight: CGFloat = 170
        let height = min(CGFloat(count) * rowHeight + 20, screen.visibleFrame.height)
        panel.setFrame(
            NSRect(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16, width: Self.width, height: height),
            display: true
        )
    }

    private func remove(_ id: UUID) {
        guard model.results.contains(where: { $0.id == id }) else { return }
        withAnimation(.spring(duration: 0.35)) { model.results.removeAll { $0.id == id } }
        let remaining = model.results.count
        Task { [weak self] in
            // Shrink the panel once the card has animated away.
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.model.results.count == remaining else { return }
            if remaining == 0 {
                self.panel.fadeOut()
            } else {
                self.layout(count: remaining)
            }
        }
    }

    fileprivate enum Action { case open, edit, copy, save, reveal, trash, close, dragged }

    private let editor = ScreenshotEditor()

    #if DEBUG
    func openEditor(_ url: URL) { editor.open(url) { _, _ in } }
    #endif

    private func perform(_ action: Action, on result: CaptureResult) {
        switch action {
        case .open:
            NSWorkspace.shared.open(result.url)
        case .edit:
            editor.open(result.url) { [weak self] _, edited in
                guard let self, let index = self.model.results.firstIndex(where: { $0.id == result.id }) else { return }
                withAnimation(.easeOut(duration: 0.25)) { self.model.results[index].thumbnail = edited }
            }
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
        case .save:
            guard save(result) else { return }
        case .trash:
            try? FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
        case .close, .dragged:
            break
        }
        if ![.reveal, .open, .edit].contains(action) { remove(result.id) }
    }

    /// Moves the capture to a place the user picks. False if cancelled.
    private func save(_ result: CaptureResult) -> Bool {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = result.url.lastPathComponent
        savePanel.directoryURL = result.url.deletingLastPathComponent()
        NSApp.activate()
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return false }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: result.url)
            } else {
                try FileManager.default.moveItem(at: result.url, to: destination)
            }
            return true
        } catch {
            HUD.show("Couldn't save: \(error.localizedDescription)")
            return false
        }
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
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
                .blur(radius: hovering ? 2 : 0)
            if result.kind == .recording, !hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
                    .transition(.opacity)
            }
            Color.black.opacity(hovering ? 0.45 : 0)
            if hovering {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ActionButton(title: "Copy", icon: "doc.on.doc") { perform(.copy) }
                        ActionButton(title: "Save", icon: "square.and.arrow.down") { perform(.save) }
                    }
                    HStack(spacing: 8) {
                        ActionButton(title: "Show", icon: "folder") { perform(.reveal) }
                        ActionButton(title: "Trash", icon: "trash") { perform(.trash) }
                    }
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                VStack {
                    HStack {
                        CloseButton { perform(.close) }
                        Spacer()
                        if result.kind == .screenshot {
                            ActionButton(title: nil, icon: "pencil.tip.crop.circle") { perform(.edit) }
                                .help("Annotate")
                        }
                        ActionButton(title: nil, icon: "arrow.up.forward.app") { perform(.open) }
                            .help("Open")
                    }
                    Spacer()
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .frame(width: 220, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(hovering ? 0.5 : 0.25)))
        .shadow(color: .black.opacity(hovering ? 0.45 : 0.3), radius: hovering ? 12 : 8, y: hovering ? 5 : 3)
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.spring(duration: 0.28, bounce: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { perform(result.kind == .screenshot ? .edit : .open) }
        .onDrag {
            // Leave once the drag is under way, like CleanShot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { perform(.dragged) }
            return NSItemProvider(contentsOf: result.url) ?? NSItemProvider()
        }
    }
}

private struct ActionButton: View {
    let title: String?
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Label(title, systemImage: icon).frame(width: 80, height: 26)
                } else {
                    Image(systemName: icon).frame(width: 26, height: 26)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .background(.white.opacity(hovering ? 0.35 : 0.2), in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
                .scaleEffect(hovering ? 1.12 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Shrinks a little while pressed.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
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
