import AppKit
import Observation
import SwiftUI

// MARK: - Switcher

@MainActor
@Observable
final class SwitcherModel {
    var query = ""
    var selection = 1

    /// Sets with windows that match the search, in number order.
    func matches(_ sets: [SetSummary]) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return sets.filter { set in
            guard !set.isEmpty else { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([set.name] + set.windows.map { "\($0.appName) \($0.title)" }).joined(separator: " ").lowercased()
            return haystack.contains(query)
        }.map(\.number)
    }
}

/// ⌃Space Space: every set in a 3×3 grid whose positions match the numbers.
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

    func show(on screen: NSScreen) {
        model.query = ""
        let occupied = controller.state.occupied
        // Opens on the previous set, so ⌃Space Space Return works like ⌘Tab.
        if let previous = controller.state.previous, occupied.contains(previous) {
            model.selection = previous
        } else {
            model.selection = controller.state.current
        }
        panel.setFrame(screen.frame, display: true)
        panel.fadeIn(duration: 0.18, makeKey: true)
        keys.start { [weak self] code, flags, _ in self?.handle(code, flags) ?? false }
    }

    func hide() {
        keys.stop()
        panel.fadeOut()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func choose(_ number: Int) {
        guard !controller.state[set: number].isEmpty || number == controller.state.current else { return }
        hide()
        controller.goTo(number)
    }

    private func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        let matches = model.matches(controller.summaries)
        let selected = matches.contains(model.selection) ? model.selection : matches.first
        if model.query.isEmpty, flags.isDisjoint(with: [.command, .control, .option]), let number = KeyCode.digit(code) {
            choose(number)
            return true
        }
        switch code {
        case KeyCode.escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
        case KeyCode.returnKey, KeyCode.enter:
            if let selected { choose(selected) }
        case KeyCode.left, KeyCode.right:
            guard !matches.isEmpty else { return true }
            let index = selected.flatMap { matches.firstIndex(of: $0) } ?? 0
            let step = code == KeyCode.right ? 1 : -1
            model.selection = matches[(index + step + matches.count) % matches.count]
        case KeyCode.up, KeyCode.down:
            let target = (selected ?? 1) + (code == KeyCode.down ? 3 : -3)
            if matches.contains(target) { model.selection = target }
        default:
            return false
        }
        return true
    }
}

private struct SwitcherView: View {
    @Bindable var model: SwitcherModel
    let controller: FocusController
    let choose: (Int) -> Void
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sets = controller.summaries
        let matches = model.matches(sets)
        let selected = matches.contains(model.selection) ? model.selection : matches.first
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.35)
                .onTapGesture(perform: dismiss)
            VStack(spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sets and windows", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 16)
                .frame(width: 560, height: 46)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(300), spacing: 24), count: 3), spacing: 24) {
                    ForEach(sets) { set in
                        SwitcherCard(
                            set: set,
                            thumbnails: controller.thumbnails,
                            query: model.query,
                            isSelected: set.number == selected,
                            isCurrent: set.number == controller.state.current,
                            dimmed: !matches.contains(set.number) && !(set.isEmpty && model.query.isEmpty),
                            pins: controller.pins,
                            togglePin: { bundleID in controller.togglePin(bundleID, to: set.number) }
                        )
                        .onTapGesture { choose(set.number) }
                    }
                }

                Text("Type to filter  ·  arrows to move  ·  Return to go  ·  1–9 to jump  ·  esc to close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { searchFocused = true }
    }
}

private struct SwitcherCard: View {
    let set: SetSummary
    let thumbnails: [WindowID: NSImage]
    let query: String
    let isSelected: Bool
    let isCurrent: Bool
    let dimmed: Bool
    let pins: [String: Int]
    let togglePin: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetPreview(set: set, thumbnails: thumbnails)
                .frame(height: 140)
            HStack(spacing: 10) {
                SetBadge(number: set.number)
                Text(set.name).font(.headline).lineLimit(1)
                Spacer()
                if isCurrent { Text("Current").font(.caption).foregroundStyle(.secondary) }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(Color.white.opacity(isSelected ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.15), lineWidth: isSelected ? 2 : 0.5)
        )
        .opacity(dimmed ? 0.3 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
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
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        if set.isEmpty { return "⌃Space ⇧\(set.number) sends a window here" }
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty, let hit = set.windows.first(where: { "\($0.appName) \($0.title)".lowercased().contains(query) }) {
            return hit.title.isEmpty ? hit.appName : "\(hit.appName) — \(hit.title)"
        }
        return set.apps
    }
}

// MARK: - Replace

/// An installed app, for "Open an app here".
struct InstalledApp: Identifiable, Sendable {
    let name: String
    let url: URL
    var id: URL { url }

    /// /Applications, /System/Applications and ~/Applications, one level of
    /// subfolders deep (Utilities and the like). Read once, off the main thread.
    static func scan() async -> [InstalledApp] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"].map(URL.init(fileURLWithPath:))
            var apps: [String: InstalledApp] = [:]
            func add(_ url: URL) {
                let name = url.deletingPathExtension().lastPathComponent
                if apps[name] == nil { apps[name] = InstalledApp(name: name, url: url) }
            }
            for root in roots {
                for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    if url.pathExtension == "app" {
                        add(url)
                    } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        for inner in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] where inner.pathExtension == "app" {
                            add(inner)
                        }
                    }
                }
            }
            return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }
}

@MainActor
@Observable
final class ReplaceModel {
    enum Item: Identifiable {
        case window(WindowSummary, set: Int)
        case app(InstalledApp)

        var id: String {
            switch self {
            case let .window(window, _): "w\(window.id)"
            case let .app(app): app.url.path
            }
        }
    }

    var query = ""
    var selection = 0
    var replacing = "window"
    var windows: [(WindowSummary, Int)] = []
    var apps: [InstalledApp] = []

    var items: [Item] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        let windowItems = windows
            .filter { query.isEmpty || "\($0.0.appName) \($0.0.title)".lowercased().contains(query) }
            .map { Item.window($0.0, set: $0.1) }
        let running = Set(windows.compactMap(\.0.bundleID))
        let appItems = apps
            .filter { query.isEmpty ? false : $0.name.lowercased().contains(query) }
            .filter { Bundle(url: $0.url)?.bundleIdentifier.map { !running.contains($0) } ?? true }
            .prefix(8)
            .map { Item.app($0) }
        return windowItems + appItems
    }
}

/// ⌃Space R: put another set's window, or a new app, where the focused one is.
@MainActor
final class ReplacePanel: NSObject, NSWindowDelegate {
    private unowned let controller: FocusController
    private let panel = FocusKeyPanel.make()
    private let model = ReplaceModel()
    private let keys = KeyMonitor()
    private var loadedApps = false

    init(controller: FocusController) {
        self.controller = controller
        super.init()
        panel.delegate = self
        panel.contentView = NSView.hosting(ReplaceView(model: model) { [weak self] item in self?.choose(item) })
    }

    func show(over slot: CGRect, replacing window: WindowSummary) {
        model.query = ""
        model.selection = 0
        model.replacing = window.appName
        model.windows = StageState.numbers
            .filter { $0 != controller.state.current }
            .flatMap { number in controller.state[set: number].windows.map { (controller.summary(of: $0), number) } }
        if !loadedApps {
            loadedApps = true
            Task { [weak self] in
                let apps = await InstalledApp.scan()
                self?.model.apps = apps
            }
        }
        let size = CGSize(width: 500, height: 460)
        let screen = NSScreen.screens.first?.visibleFrame ?? slot
        var origin = CGPoint(x: slot.midX - size.width / 2, y: slot.maxY - 120 - size.height)
        origin.x = min(max(origin.x, screen.minX + 12), screen.maxX - size.width - 12)
        origin.y = min(max(origin.y, screen.minY + 12), screen.maxY - size.height - 12)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.fadeIn(duration: 0.15, rise: 8, makeKey: true)
        keys.start { [weak self] code, _, _ in self?.handle(code) ?? false }
    }

    func hide() {
        keys.stop()
        panel.fadeOut()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func choose(_ item: ReplaceModel.Item) {
        hide()
        switch item {
        case let .window(window, _): controller.replace(with: window.id)
        case let .app(app): controller.replace(withApp: app.url)
        }
    }

    private func handle(_ code: UInt16) -> Bool {
        let items = model.items
        switch code {
        case KeyCode.escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
        case KeyCode.down:
            model.selection = min(model.selection + 1, max(items.count - 1, 0))
        case KeyCode.up:
            model.selection = max(model.selection - 1, 0)
        case KeyCode.returnKey, KeyCode.enter:
            if items.indices.contains(model.selection) { choose(items[model.selection]) }
        default:
            return false
        }
        return true
    }
}

private struct ReplaceView: View {
    @Bindable var model: ReplaceModel
    let choose: (ReplaceModel.Item) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.items
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Replace \(model.replacing) with…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onChange(of: model.query) { model.selection = 0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty {
                        Text(model.query.isEmpty ? "No windows in other sets. Type an app name." : "No window or app matches.")
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0, case .window = item { header("Windows in other sets") }
                        if case .app = item, index == 0 || isWindow(items[index - 1]) { header("Open an app here") }
                        row(item, selected: index == model.selection)
                            .onTapGesture { choose(item) }
                    }
                }
                .padding(8)
            }
            Divider()
            Text("Return to replace  ·  \(model.replacing) goes where the new window came from  ·  esc to cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { searchFocused = true }
    }

    private func isWindow(_ item: ReplaceModel.Item) -> Bool {
        if case .window = item { return true }
        return false
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    @ViewBuilder private func row(_ item: ReplaceModel.Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case let .window(window, number):
                icon(window.icon)
                Text(window.appName).fontWeight(.semibold)
                Text(window.title).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary).lineLimit(1)
                Spacer()
                Text("Set \(number)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            case let .app(app):
                icon(NSWorkspace.shared.icon(forFile: app.url.path))
                Text(app.name).fontWeight(.semibold)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Rectangle())
    }

    private func icon(_ image: NSImage?) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Color.secondary.opacity(0.2) }
        }
        .frame(width: 24, height: 24)
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
        let hosting = NSHostingView(rootView: ShelfView(sets: sets, thumbnails: controller.thumbnails) { [weak self] number in
            self?.hide()
            self?.controller.goTo(number)
        })
        let size = hosting.fittingSize
        hosting.frame.size = size
        panel.contentView = NSView.container(for: hosting)
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.minX + 10, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.fadeIn(duration: 0.15)
    }

    func hide() {
        revealTask?.cancel()
        panel.fadeOut()
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
        if panel.isVisible {
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
    let thumbnails: [WindowID: NSImage]
    let choose: (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(sets) { set in
                Button { choose(set.number) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SetPreview(set: set, thumbnails: thumbnails)
                            .frame(width: 140, height: 80)
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
            Text("⌃Space Space for all sets")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 176)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.1)))
    }
}
