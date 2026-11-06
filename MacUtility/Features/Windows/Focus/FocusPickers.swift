import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

// MARK: - Switcher

@MainActor
@Observable
final class SwitcherModel {
    var selection = 1
    /// Drives the open and close motion; the panel itself stays opaque.
    var isPresented = false

    /// Moves within the 3×3 grid, stopping at its edges.
    func move(columns: Int, rows: Int) {
        let row = (selection - 1) / 3 + rows
        let column = (selection - 1) % 3 + columns
        guard (0..<3).contains(row), (0..<3).contains(column) else { return }
        selection = row * 3 + column + 1
    }
}

/// Leader, Space: every set in a 3×3 grid whose positions match the numbers.
@MainActor
final class SwitcherPanel: NSObject, NSWindowDelegate {
    private unowned let controller: FocusController
    private let panel = FocusKeyPanel.make()
    private let model = SwitcherModel()
    private let keys = KeyMonitor()

    init(controller: FocusController) {
        self.controller = controller
        super.init()
        panel.delegate = self
        panel.contentView = NSView.hosting(SwitcherView(model: model, controller: controller) { [weak self] number in
            self?.choose(number)
        } dismiss: { [weak self] in
            self?.hide()
        })
    }

    var isVisible: Bool { panel.isVisible && model.isPresented }
    private var hideTask: Task<Void, Never>?

    func show(on screen: NSScreen) {
        hideTask?.cancel()
        let occupied = controller.state.occupied
        // Opens on the previous set, so leader, Space, Return works like ⌘Tab.
        if let previous = controller.state.previous, occupied.contains(previous) {
            model.selection = previous
        } else {
            model.selection = controller.state.current
        }
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        // One frame at rest first, so SwiftUI has a "from" state to animate.
        Task { @MainActor [model] in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.isPresented = true }
        }
        keys.start { [weak self] code, flags, chars in self?.handle(code, flags, chars) ?? false }
    }

    func hide() {
        keys.stop()
        guard model.isPresented else { return }
        withAnimation(.easeIn(duration: 0.14)) { model.isPresented = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !self.model.isPresented else { return }
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func choose(_ number: Int) {
        hide()
        controller.goTo(number)
    }

    /// hjkl or arrows move, Return goes, 1–9 jump, esc closes. Every other
    /// key is swallowed: there's nothing to type into.
    private func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> Bool {
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        if let number = KeyCode.digit(code) {
            choose(number)
            return true
        }
        switch code {
        case KeyCode.escape: hide()
        case KeyCode.returnKey, KeyCode.enter: choose(model.selection)
        case KeyCode.left: model.move(columns: -1, rows: 0)
        case KeyCode.right: model.move(columns: 1, rows: 0)
        case KeyCode.up: model.move(columns: 0, rows: -1)
        case KeyCode.down: model.move(columns: 0, rows: 1)
        default:
            switch chars.lowercased() {
            case "h": model.move(columns: -1, rows: 0)
            case "l": model.move(columns: 1, rows: 0)
            case "k": model.move(columns: 0, rows: -1)
            case "j": model.move(columns: 0, rows: 1)
            default: break
            }
        }
        return true
    }
}

private struct SwitcherView: View {
    @Bindable var model: SwitcherModel
    let controller: FocusController
    let choose: (Int) -> Void
    let dismiss: () -> Void

    private let cardWidth: CGFloat = 288
    private let spacing: CGFloat = 20

    var body: some View {
        let sets = controller.summaries
        ZStack {
            // Backdrop: the stage blurred and dimmed, like Mission Control.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.42))
                .opacity(model.isPresented ? 1 : 0)
                .onTapGesture(perform: dismiss)

            VStack(spacing: 24) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: 3), spacing: spacing) {
                    ForEach(sets) { set in
                        SwitcherCard(
                            set: set,
                            thumbnails: controller.thumbnails,
                            isSelected: set.number == model.selection,
                            isCurrent: set.number == controller.state.current,
                            pins: controller.pins,
                            togglePin: { bundleID in controller.togglePin(bundleID, to: set.number) }
                        )
                        .onTapGesture { choose(set.number) }
                        .onHover { if $0 { model.selection = set.number } }
                    }
                }

                HStack(spacing: 14) {
                    KeyHint(keys: "h j k l", label: "Move")
                    KeyHint(keys: "↩", label: "Go")
                    KeyHint(keys: "1–9", label: "Jump")
                    KeyHint(keys: "esc", label: "Close")
                }
            }
            .scaleEffect(model.isPresented ? 1 : 0.96)
            .opacity(model.isPresented ? 1 : 0)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

private struct SwitcherCard: View {
    let set: SetSummary
    let thumbnails: [WindowID: NSImage]
    let isSelected: Bool
    let isCurrent: Bool
    let pins: [String: Int]
    let togglePin: (String) -> Void
    private let radius: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SetPreview(set: set, thumbnails: thumbnails, cornerRadius: 8)
            HStack(spacing: 8) {
                SetBadge(number: set.number, size: 20)
                    .opacity(set.isEmpty ? 0.5 : 1)
                if !set.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(set.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                if isCurrent {
                    Text("Current")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 30)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.16 : set.isEmpty ? 0.025 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.08), lineWidth: isSelected ? 2.5 : 1)
        )
        .scaleEffect(isSelected ? 1.02 : 1)
        .opacity(set.isEmpty && !isSelected ? 0.6 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contextMenu {
            ForEach(set.windows) { window in
                if let bundleID = window.bundleID {
                    Button(pins[bundleID] == set.number ? "Unpin \(window.appName) from Set \(set.number)" : "Pin \(window.appName) to Set \(set.number)") {
                        togglePin(bundleID)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(set.isEmpty ? "Set \(set.number), empty" : "Set \(set.number), \(set.apps)")
        .accessibilityAddTraits(.isButton)
    }

    /// What the name doesn't already say: the second app, or the window's title.
    private var subtitle: String? {
        if set.windows.count == 2 { return set.apps }
        let title = set.windows.first?.title ?? ""
        return title.isEmpty || title == set.name ? nil : title
    }
}

// MARK: - Replace

@MainActor
@Observable
final class ReplaceModel {
    enum Item: Identifiable {
        case window(WindowSummary, set: Int)
        case app(name: String, url: URL, icon: NSImage?)

        var id: String {
            switch self {
            case let .window(window, _): "w\(window.id)"
            case let .app(_, url, _): url.path
            }
        }
    }

    enum Mode: Equatable {
        case replace
        case split(SplitAxis)
    }

    var mode = Mode.replace
    var selection = 0
    /// The window being replaced, or the one the new pane opens beside.
    var replacing: WindowSummary?
    var items: [Item] = []
    /// Drives the open and close motion; the panel itself stays opaque.
    var isPresented = false

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + step, 0), items.count - 1)
    }
}

/// Leader, R: put another set's window, or a running app, where the focused
/// window is. Sits over that window, which dims behind it. Leader v/s reuse
/// it in the empty pane of a fresh split.
@MainActor
final class ReplacePanel: NSObject, NSWindowDelegate {
    private unowned let controller: FocusController
    private let panel = FocusKeyPanel.make()
    private let model = ReplaceModel()
    private let keys = KeyMonitor()
    private var hideTask: Task<Void, Never>?

    init(controller: FocusController) {
        self.controller = controller
        super.init()
        panel.delegate = self
        panel.contentView = NSView.hosting(ReplaceView(model: model) { [weak self] item in
            self?.choose(item)
        } dismiss: { [weak self] in
            self?.cancel()
        })
    }

    func show(over slot: CGRect, replacing window: WindowSummary) {
        model.mode = .replace
        present(over: slot, window: window)
    }

    /// The empty pane of a split that just opened.
    func showSplit(over pane: CGRect, beside window: WindowSummary, axis: SplitAxis) {
        model.mode = .split(axis)
        present(over: pane, window: window)
    }

    private func present(over slot: CGRect, window: WindowSummary) {
        hideTask?.cancel()
        model.selection = 0
        model.replacing = window
        model.items = items()
        panel.setFrame(slot, display: true)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        Task { @MainActor [model] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { model.isPresented = true }
        }
        keys.start { [weak self] code, flags, chars in self?.handle(code, flags, chars) ?? false }
    }

    func hide() {
        keys.stop()
        guard model.isPresented else { return }
        withAnimation(.easeIn(duration: 0.14)) { model.isPresented = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !self.model.isPresented else { return }
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        cancel()
    }

    /// Closed without choosing: a split gives its pane back.
    private func cancel() {
        let wasOpen = model.isPresented
        hide()
        if wasOpen, case .split = model.mode { controller.cancelSplit() }
    }

    /// Windows parked in other sets, then running apps with no window in any
    /// set (choosing one opens a window for it here).
    private func items() -> [ReplaceModel.Item] {
        let state = controller.state
        let windows = StageState.numbers
            .filter { $0 != state.current }
            .flatMap { number in state[set: number].windows.map { ReplaceModel.Item.window(controller.summary(of: $0), set: number) } }
        let managedPIDs = Set(state.allWindows.compactMap { controller.registry.windows[$0]?.pid })
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own && !managedPIDs.contains($0.processIdentifier) }
            .compactMap { app -> ReplaceModel.Item? in
                guard let url = app.bundleURL else { return nil }
                return .app(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, url: url, icon: app.icon)
            }
            .sorted { a, b in
                guard case let .app(nameA, _, _) = a, case let .app(nameB, _, _) = b else { return false }
                return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
            }
        return windows + apps
    }

    private func choose(_ item: ReplaceModel.Item) {
        hide()
        switch (model.mode, item) {
        case let (.replace, .window(window, _)): controller.replace(with: window.id)
        case let (.replace, .app(_, url, _)): controller.replace(withApp: url)
        case let (.split, .window(window, _)): controller.split(with: window.id)
        case let (.split, .app(_, url, _)): controller.split(withApp: url)
        }
    }

    /// j/k or arrows move, Return replaces, esc cancels. Everything else is
    /// swallowed: there's nothing to type into.
    private func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> Bool {
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch code {
        case KeyCode.escape: cancel()
        case KeyCode.down: model.move(1)
        case KeyCode.up: model.move(-1)
        case KeyCode.returnKey, KeyCode.enter:
            if model.items.indices.contains(model.selection) { choose(model.items[model.selection]) }
        default:
            switch chars.lowercased() {
            case "j": model.move(1)
            case "k": model.move(-1)
            default: break
            }
        }
        return true
    }
}

private struct ReplaceView: View {
    @Bindable var model: ReplaceModel
    let choose: (ReplaceModel.Item) -> Void
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Replace: the window, dimmed and outlined in place.
                // Split: the new, empty pane.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSplit ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: isSplit ? 2 : 3, dash: isSplit ? [8, 6] : []))
                    )
                    .background(isSplit ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(model.isPresented ? 1 : 0)
                    .onTapGesture(perform: dismiss)

                card
                    .frame(width: min(440, proxy.size.width - 48))
                    .frame(maxHeight: min(560, proxy.size.height - 80))
                    .scaleEffect(model.isPresented ? 1 : 0.96)
                    .opacity(model.isPresented ? 1 : 0)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var isSplit: Bool {
        if case .split = model.mode { return true }
        return false
    }

    private var heading: String {
        let name = model.replacing?.appName ?? "window"
        switch model.mode {
        case .replace: return "Replace \(name)"
        case .split(.vertical): return "Open beside \(name)"
        case .split(.horizontal): return "Open below \(name)"
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                icon(model.replacing?.icon, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(heading)
                        .font(.system(size: 15, weight: .semibold))
                    if let title = model.replacing?.title, !title.isEmpty, title != model.replacing?.appName {
                        Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            if model.items.isEmpty {
                Text("No windows in other sets, and every running app already has one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                if let title = header(at: index) { sectionTitle(title) }
                                row(item, selected: index == model.selection)
                                    .id(item.id)
                                    .onTapGesture { choose(item) }
                                    .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selection) { _, selection in
                        guard model.items.indices.contains(selection) else { return }
                        withAnimation(.easeOut(duration: 0.12)) { scroll.scrollTo(model.items[selection].id) }
                    }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 14) {
                hint("j k", "Move")
                hint("↩", isSplit ? "Open here" : "Replace")
                hint("esc", "Cancel")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Near-solid: a material in a panel of an inactive app renders
        // translucent, and the window underneath bled through it.
        .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }

    private func header(at index: Int) -> String? {
        let item = model.items[index]
        let previous = index > 0 ? model.items[index - 1] : nil
        switch (item, previous) {
        case (.window, nil): return "Windows in other sets"
        case (.app, nil), (.app, .window?): return "Open apps"
        default: return nil
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row(_ item: ReplaceModel.Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case let .window(window, number):
                icon(window.icon, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.appName).font(.system(size: 13, weight: .semibold))
                    if !window.title.isEmpty, window.title != window.appName {
                        Text(window.title)
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                SetBadge(number: number, size: 18)
            case let .app(name, _, image):
                icon(image, size: 24)
                Text(name).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("New window").font(.system(size: 11)).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.1), value: selected)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func icon(_ image: NSImage?, size: CGFloat) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)) }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Shelf

/// The other sets as a strip at the left edge. Shows when the pointer rests
/// at the edge, or with the leader's key guide.
@MainActor
final class ShelfPanel {
    private unowned let controller: FocusController
    private let panel: NSPanel
    private var pointerMonitor: Any?
    private var revealTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private let presence = Presence()

    init(controller: FocusController) {
        self.controller = controller
        // Key-capable so a click on a card lands on the first try.
        panel = FocusKeyPanel.make()
    }

    func show(on screen: NSScreen) {
        let sets = controller.summaries.filter { !$0.isEmpty && $0.number != controller.state.current }
        guard !sets.isEmpty else {
            hide()
            return
        }
        hideTask?.cancel()
        let wasShowing = panel.isVisible && presence.isPresented
        let hosting = NSHostingView(rootView: ShelfView(sets: sets, controller: controller, presence: presence) { [weak self] number in
            self?.hide()
            self?.controller.goTo(number)
        })
        let size = hosting.fittingSize
        hosting.frame.size = size
        panel.contentView = NSView.container(for: hosting)
        let visible = screen.visibleFrame
        // Flush with the screen edge, so the strip slides in from off screen.
        panel.setFrame(CGRect(x: screen.frame.minX, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        guard !wasShowing else { return }
        presence.isPresented = false
        Task { @MainActor [presence] in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { presence.isPresented = true }
        }
    }

    func hide() {
        revealTask?.cancel()
        guard panel.isVisible, presence.isPresented else { return }
        withAnimation(.easeIn(duration: 0.16)) { presence.isPresented = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, !self.presence.isPresented else { return }
            self.panel.orderOut(nil)
        }
    }

    func startWatchingPointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { [weak self] in self?.pointerMoved(to: location) }
        }
    }

    func stopWatchingPointer() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
    }

    private func pointerMoved(to location: CGPoint) {
        guard let screen = NSScreen.screens.first else { return }
        if panel.isVisible, presence.isPresented {
            if !panel.frame.insetBy(dx: -40, dy: -40).contains(location) { hide() }
            return
        }
        let atEdge = location.x <= screen.frame.minX + 1 && screen.frame.contains(CGPoint(x: location.x + 1, y: location.y))
        if atEdge {
            guard revealTask == nil else { return }
            revealTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.revealTask = nil
                if NSEvent.mouseLocation.x <= screen.frame.minX + 1 { self.show(on: screen) }
            }
        } else {
            revealTask?.cancel()
            revealTask = nil
        }
    }
}

private struct ShelfView: View {
    let sets: [SetSummary]
    let controller: FocusController
    let presence: Presence
    let choose: (Int) -> Void

    // Read through the controller so cards update as fresh captures land.
    private var thumbnails: [WindowID: NSImage] { controller.thumbnails }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(sets) { set in
                Button { choose(set.number) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SetPreview(set: set, thumbnails: thumbnails, cornerRadius: 7)
                            .frame(width: 140)
                        HStack(spacing: 8) {
                            SetBadge(number: set.number, size: 20)
                            Text(set.name).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        if set.windows.count > 1 {
                            Text(set.apps).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            Text("\(KeyboardShortcuts.Name.focusLeaderLabel) Space for all sets")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 176)
        .background(.panelFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 4, y: 6)
        .padding(.leading, 10)
        .padding([.vertical, .trailing], 24)
        // Slides in from the left edge.
        .offset(x: presence.isPresented ? 0 : -220)
        .opacity(presence.isPresented ? 1 : 0.6)
    }
}
