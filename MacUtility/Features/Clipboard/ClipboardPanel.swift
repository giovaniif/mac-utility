import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ClipboardPanelModel {
    var query = ""
    var selection = 0
    let store: ClipboardStore

    init(store: ClipboardStore) { self.store = store }

    var results: [ClipboardItem] {
        guard let matches = store.search(query) else { return store.items }
        return store.items.filter { matches.contains($0.id) }
    }

    var selected: ClipboardItem? {
        let results = results
        return results.indices.contains(selection) ? results[selection] : nil
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
}

/// Key-capable panel that doesn't activate the app, so the target app stays
/// frontmost and receives the paste.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Paste-style strip of cards along the bottom of the active display. Built
/// once and kept warm.
@MainActor
final class ClipboardPanel: NSObject, NSWindowDelegate {
    enum Command {
        case paste(ClipboardItem, plainText: Bool)
    }

    let model: ClipboardPanelModel
    var onCommand: (Command) -> Void = { _ in }

    private let panel: NSPanel
    private var keyMonitor: Any?
    private static let height: CGFloat = 300

    var isVisible: Bool { panel.isVisible }

    init(store: ClipboardStore) {
        model = ClipboardPanelModel(store: store)
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = NSView.hosting(ClipboardPanelView(model: model) { [weak self] item in
            self?.onCommand(.paste(item, plainText: false))
        })
    }

    func show() {
        model.query = ""
        model.selection = 0
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let margin: CGFloat = 12
            panel.setFrame(
                NSRect(x: frame.minX + margin, y: frame.minY + margin, width: frame.width - margin * 2, height: Self.height),
                display: true
            )
        }
        panel.fadeIn(duration: 0.2, rise: 16, makeKey: true)
        installKeyMonitor()
    }

    /// Pasting hides instantly so key focus is back in the target app before ⌘V.
    func hide(animated: Bool = true) {
        removeKeyMonitor()
        if animated {
            panel.fadeOut()
        } else {
            panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""
            let handled = MainActor.assumeIsolated {
                self?.handleKey(keyCode: keyCode, flags: flags, chars: chars) ?? false
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, chars: String) -> Bool {
        switch keyCode {
        case 53: // Esc
            hide()
        case 123: // ←
            model.move(-1)
        case 124: // →
            model.move(1)
        case 36, 76: // Return, Enter
            guard let item = model.selected else { return true }
            onCommand(.paste(item, plainText: flags.contains(.shift)))
        case 51 where model.query.isEmpty: // ⌫
            guard let item = model.selected else { return true }
            model.store.delete(item.id)
            model.move(0)
        default:
            guard flags.contains(.command) else { return false }
            if let digit = Int(chars), (1...9).contains(digit) {
                let results = model.results
                guard results.indices.contains(digit - 1) else { return true }
                onCommand(.paste(results[digit - 1], plainText: flags.contains(.shift)))
            } else if chars.lowercased() == "p", let item = model.selected {
                model.store.togglePin(item.id)
            } else {
                return false
            }
        }
        return true
    }
}

private struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    let onPaste: (ClipboardItem) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = model.results
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onChange(of: model.query) { model.selection = 0 }
                Spacer()
                Text("⏎ paste  ⇧⏎ plain  ⌘P pin  ⌫ delete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            if results.isEmpty {
                Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                ClipboardCard(
                                    item: item,
                                    index: index,
                                    selected: index == model.selection,
                                    thumbnail: model.store.thumbnail(for: item)
                                )
                                .id(item.id)
                                .onTapGesture(count: 2) { onPaste(item) }
                                .onTapGesture { model.selection = index }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .animation(.spring(duration: 0.3), value: results.map(\.id))
                    }
                    .onChange(of: model.selection) {
                        if let item = model.selected {
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item.id) }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear { searchFocused = true }
    }
}

private struct ClipboardCard: View {
    let item: ClipboardItem
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon = AppIcon.image(for: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if item.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                }
                if index < 9 {
                    Text("⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(width: 220, height: 210)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .scaleEffect(selected ? 1.03 : hovering ? 1.015 : 1)
        .shadow(color: .black.opacity(selected || hovering ? 0.25 : 0), radius: 8, y: 3)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: selected)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text, .richText:
            Text(item.text ?? "")
                .font(.callout)
                .lineLimit(9)
        case .image:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Label("Image", systemImage: "photo")
            }
        case .files:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.fileURLs ?? [], id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "doc")
                        .font(.callout)
                        .lineLimit(1)
                }
            }
        }
    }
}

@MainActor
private enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
