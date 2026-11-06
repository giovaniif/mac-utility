import AppKit
import ApplicationServices
import Observation
import os

/// What the HUD, switcher, shelf and menu bar show about one window.
struct WindowSummary: Identifiable {
    let id: WindowID
    let appName: String
    let title: String
    let bundleID: String?
    let icon: NSImage?
}

/// What the UI shows about one set.
struct SetSummary: Identifiable {
    let number: Int
    let windows: [WindowSummary]
    let isSplit: Bool
    var id: Int { number }
    var isEmpty: Bool { windows.isEmpty }
    var name: String { windows.first?.appName ?? "Set \(number)" }
    var apps: String { windows.map(\.appName).joined(separator: " · ") }
}

/// Focus: one display, one stage. Owns the sets, listens to the registry,
/// and moves real windows to match `state`.
@MainActor
@Observable
final class FocusController {
    private(set) var isRunning = false
    private(set) var state = StageState()
    private(set) var pins: [String: Int] = [:]
    /// Snapshots of windows taken before they were parked, for cards.
    private(set) var thumbnails: [WindowID: NSImage] = [:]

    @ObservationIgnored let registry = WindowRegistry()
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let log = Logger(subsystem: "com.giovani.MacUtility", category: "focus")
    @ObservationIgnored private lazy var leader = LeaderKey(controller: self)
    @ObservationIgnored private lazy var switcher = SwitcherPanel(controller: self)
    @ObservationIgnored private lazy var replacer = ReplacePanel(controller: self)
    @ObservationIgnored private lazy var shelf = ShelfPanel(controller: self)
    @ObservationIgnored private lazy var motion = StageMotion()

    @ObservationIgnored private var homes: [WindowID: CGRect] = [:]
    @ObservationIgnored private var parked: Set<WindowID> = []
    @ObservationIgnored private var memory: [String: Int] = [:]
    /// Floated by the user with the leader's `\`.
    @ObservationIgnored private var floating: Set<WindowID> = []
    /// Didn't fit anywhere: every set was full.
    @ObservationIgnored private var overflow: Set<WindowID> = []
    /// Minimized or hidden windows and the set they come back to.
    @ObservationIgnored private var away: [WindowID: Int] = [:]
    @ObservationIgnored private var ownChangeUntil: [WindowID: Date] = [:]
    @ObservationIgnored private var focusMutedUntil = Date.distantPast
    @ObservationIgnored private var zoomed: WindowID?
    @ObservationIgnored private var pendingReplace: (target: WindowID, bundleID: String, until: Date, before: StageState)?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var adopting = false
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var appliedWidthCap = 0.0

    /// Never tiled: utility apps whose windows are fixed panels at heart.
    private static let floatingApps: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.calculator",
        "com.apple.archiveutility",
        "com.apple.ScreenSharing",
        "com.apple.PhotoBooth",
    ]

    static var widthCap: Double {
        let stored = UserDefaults.standard.double(forKey: "focus.widthCap")
        return stored > 0 ? stored : 1440
    }

    init(permissions: Permissions) {
        self.permissions = permissions
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .featureToggled, object: nil, queue: .main) { note in
            guard let feature = note.object as? Feature, feature == .focus else { return }
            MainActor.assumeIsolated { [weak self] in self?.syncWithFeature() }
        })
        tokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.apply(focus: false) }
        })
        tokens.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isRunning, Self.widthCap != self.appliedWidthCap else { return }
                self.apply(focus: false)
            }
        })
    }

    // MARK: Lifecycle

    /// Called at launch and whenever the Focus switch changes.
    func syncWithFeature() {
        if Feature.focus.isEnabled {
            start()
        } else {
            stop()
            FocusStore.recoverIfNeeded()
        }
    }

    func start() {
        guard !isRunning else { return }
        permissions.refresh()
        guard permissions.accessibility else {
            permissions.requestAccessibility()
            HUD.show("Focus needs Accessibility")
            return
        }
        if StageManager.isEnabled {
            UserDefaults.standard.set(false, forKey: Feature.focus.defaultsKey)
            Feature.focus.applyHotkeys()
            StageManager.explain()
            return
        }
        let snapshot = FocusStore.load()
        state = snapshot.state
        homes = snapshot.homes
        parked = snapshot.parked
        memory = snapshot.memory
        pins = snapshot.pins

        adopting = true
        registry.onEvent = { [weak self] event in self?.handle(event) }
        registry.start()
        adopting = false
        isRunning = true
        adoptAll()
        shelf.startWatchingPointer()
        apply(focus: true)
        log.notice("focus started with \(self.state.allWindows.count) windows")
    }

    /// Brings every parked window back to where it last was on the stage.
    func stop() {
        guard isRunning else { return }
        leader.disarm()
        switcher.hide()
        replacer.hide()
        shelf.stopWatchingPointer()
        shelf.hide()
        let fallback = layout.single
        for id in state.allWindows where parked.contains(id) {
            guard let window = registry.windows[id], let size = window.frame?.size else { continue }
            let home = homes[id] ?? CGRect(x: fallback.midX - size.width / 2, y: fallback.minY, width: size.width, height: size.height)
            window.element.setFrame(home)
        }
        parked.removeAll()
        registry.stop()
        isRunning = false
        zoomed = nil
        save(active: false)
        log.notice("focus stopped")
    }

    /// First run, or windows that opened while Focus was off.
    private func adoptAll() {
        let windows = registry.windowsFrontToBack().filter { isManageable($0) && (state.contains($0.id) || isOnDisplay($0)) }
        state.prune(keeping: Set(windows.map(\.id)))
        parked.formIntersection(state.allWindows)
        let fresh = windows.filter { !state.contains($0.id) }
        if state.allWindows.isEmpty {
            overflow.formUnion(state.adopt(fresh.map { ($0.id, $0.bundleID ?? $0.appName) }))
        } else {
            for window in fresh where state.add(window.id, preferred: preferredSet(for: window), activate: false) == .unmanaged {
                overflow.insert(window.id)
            }
        }
    }

    // MARK: Geometry

    private var display: NSScreen? { NSScreen.screens.first }
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func ax(_ cocoa: CGRect) -> CGRect { ScreenGeometry.flip(cocoa, primaryHeight: primaryHeight) }

    var layout: StageLayout {
        StageLayout(stage: ax(display?.visibleFrame ?? .zero), gap: 12, widthCap: CGFloat(Self.widthCap))
    }

    private var displayRect: CGRect { ax(display?.frame ?? .zero) }

    /// Converts an Accessibility rect to Cocoa screen coordinates, for panels.
    func cocoa(_ axRect: CGRect) -> CGRect { ScreenGeometry.flip(axRect, primaryHeight: primaryHeight) }

    private func isOnDisplay(_ window: TrackedWindow) -> Bool {
        guard let frame = window.frame else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if displayRect.contains(center) { return true }
        // An app that quit while parked reopens its window in the parking
        // corner, almost entirely off screen. It still belongs here.
        let onAnyDisplay = NSScreen.screens.contains { ax($0.frame).contains(center) }
        return !onAnyDisplay && displayRect.intersects(frame)
    }

    private func isManageable(_ window: TrackedWindow) -> Bool {
        guard !floating.contains(window.id), !window.isMinimized, !window.isFullScreen,
              window.app?.isHidden != true,
              window.element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
              window.element.isSettable(kAXSizeAttribute), window.element.isSettable(kAXPositionAttribute),
              let frame = window.frame, frame.width >= 200, frame.height >= 150 else { return false }
        if let bundleID = window.bundleID, Self.floatingApps.contains(bundleID) { return false }
        return true
    }

    // MARK: Placing windows

    /// Moves real windows to match `state`: the current set on the stage,
    /// everything else parked. `focus` raises the set's focused window.
    func apply(focus: Bool = true) {
        guard isRunning else { return }
        let set = state.currentSet
        appliedWidthCap = Self.widthCap
        let frames = layout.frames(for: set, zoomed: zoomed)
        focusMutedUntil = Date().addingTimeInterval(0.5)
        for (id, rect) in frames { place(id, rect) }
        if focus {
            for id in frames.keys where id != set.focused { registry.raise(id) }
            if let focused = set.focused, frames[focused] != nil {
                registry.raise(focused)
            } else if frames.isEmpty {
                // Empty set: nothing to type into, so hand focus to the desktop.
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            }
        }
        for id in state.allWindows where frames[id] == nil { park(id) }
        rememberSets()
        scheduleSave()
    }

    private func place(_ id: WindowID, _ rect: CGRect) {
        guard let window = registry.windows[id] else { return }
        homes[id] = rect
        parked.remove(id)
        if let frame = window.frame, abs(frame.minX - rect.minX) < 1, abs(frame.minY - rect.minY) < 1,
           abs(frame.width - rect.width) < 1, abs(frame.height - rect.height) < 1 { return }
        markOwnChange(id)
        window.element.setFrame(rect)
    }

    private func park(_ id: WindowID) {
        guard let window = registry.windows[id], let frame = window.frame else { return }
        let others = NSScreen.screens.dropFirst().map { ax($0.frame) }
        let origin = StageLayout.parkingOrigin(size: frame.size, display: displayRect, otherDisplays: others)
        if !parked.contains(id), displayRect.intersects(frame) { homes[id] = frame }
        parked.insert(id)
        guard abs(frame.minX - origin.x) >= 1 || abs(frame.minY - origin.y) >= 1 else { return }
        markOwnChange(id)
        window.element.set(kAXPositionAttribute, point: origin)
    }

    private func markOwnChange(_ id: WindowID) {
        ownChangeUntil[id] = Date().addingTimeInterval(0.6)
    }

    /// Switch sets with a short crossfade (skipped with Reduce Motion or no
    /// Screen Recording). The snapshot also feeds the cards' thumbnails.
    private func transition(_ change: @escaping () -> Void) {
        let visible = layout.frames(for: state.currentSet, zoomed: zoomed)
        guard let display else {
            change()
            return
        }
        motion.crossfade(on: display, capturing: visible.mapValues(cocoa)) { [weak self] shots in
            guard let self else { return }
            for (id, image) in shots { self.thumbnails[id] = image }
            change()
        }
    }

    // MARK: Events

    private func handle(_ event: WindowRegistry.Event) {
        guard !adopting, isRunning else { return }
        switch event {
        case let .appeared(id):
            windowAppeared(id)
        case let .disappeared(id):
            windowGone(id)
        case let .focused(id):
            focusChanged(id)
        case let .minimized(id):
            if let number = state.remove(id) {
                away[id] = number
                apply(focus: number == state.current)
            }
        case let .restored(id):
            if let number = away.removeValue(forKey: id) {
                add(id, preferred: number, activate: true)
            } else {
                windowAppeared(id)
            }
        case let .moved(id), let .resized(id):
            userChanged(id)
        case let .appHidden(pid):
            var touched = false
            for (id, window) in registry.windows where window.pid == pid {
                if let number = state.remove(id) {
                    away[id] = number
                    touched = touched || number == state.current
                }
            }
            if touched { apply(focus: false) }
        case let .appShown(pid):
            for (id, window) in registry.windows where window.pid == pid {
                if let number = away.removeValue(forKey: id) { state.add(id, preferred: number, activate: false) }
            }
            apply(focus: false)
        }
    }

    private func windowAppeared(_ id: WindowID) {
        guard !state.contains(id), !overflow.contains(id), let window = registry.windows[id],
              isManageable(window), isOnDisplay(window) else { return }

        if let pending = pendingReplace, pending.bundleID == window.bundleID, Date() < pending.until, state.contains(pending.target) {
            pendingReplace = nil
            let went = state.replace(pending.target, withNew: id)
            if went == nil { overflow.insert(pending.target) }
            apply()
            showReplaced(id, replaced: pending.target, went: went, undo: pending.before)
            return
        }
        // Freshly launched apps aren't frontmost yet when their first window shows.
        let launchedNow = window.app?.launchDate.map { Date().timeIntervalSince($0) < 5 } ?? false
        let isFront = window.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier || launchedNow
        add(id, preferred: preferredSet(for: window), activate: isFront)
    }

    private func add(_ id: WindowID, preferred: Int?, activate: Bool) {
        switch state.add(id, preferred: preferred, activate: activate) {
        case .joinedCurrent:
            apply(focus: activate)
        case let .placed(number, switched, becauseFull):
            apply(focus: switched)
            if switched {
                let message = becauseFull ? "Set \(state.previous ?? number) already had two windows. ⌃Space ⇥ goes back." : nil
                showHUD(for: number, message: message)
            }
        case .unmanaged:
            overflow.insert(id)
            HUD.show("Every set is full")
        }
    }

    private func windowGone(_ id: WindowID) {
        floating.remove(id)
        overflow.remove(id)
        away[id] = nil
        homes[id] = nil
        parked.remove(id)
        ownChangeUntil[id] = nil
        thumbnails[id] = nil
        if zoomed == id { zoomed = nil }
        if pendingReplace?.target == id { pendingReplace = nil }
        if let number = state.remove(id) {
            apply(focus: number == state.current)
        }
    }

    private func focusChanged(_ id: WindowID) {
        guard Date() > focusMutedUntil, state.contains(id) else { return }
        let changed = state.focus(id)
        if changed {
            // ⌘Tab or a Dock click on a parked window: the stage follows it.
            zoomed = nil
            apply(focus: false)
            showHUD(for: state.current, message: nil)
        } else if state.currentSet.layout == .stacked {
            apply(focus: false)
        } else {
            scheduleSave()
        }
    }

    /// The user dragged or resized a window, or an app moved its own.
    private func userChanged(_ id: WindowID) {
        if let until = ownChangeUntil[id], Date() < until { return }
        guard let window = registry.windows[id] else { return }
        if !state.contains(id) {
            // A window arriving on this display, e.g. with ⌃⌘← or a drag.
            if !overflow.contains(id), !away.keys.contains(id) { windowAppeared(id) }
            return
        }
        if !parked.contains(id), !isOnDisplay(window) {
            // Dragged to another display: it leaves its set.
            state.remove(id)
            apply(focus: false)
            return
        }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.settle(id)
        }
    }

    /// After a resize stops: a split side's new width becomes the ratio.
    /// Anything else snaps back into place.
    private func settle(_ id: WindowID) {
        let set = state.currentSet
        if set.windows.count == 2, set.layout == .split, zoomed == nil,
           let index = set.windows.firstIndex(of: id),
           let frame = registry.windows[id]?.frame,
           let expected = layout.frames(for: set)[id],
           abs(frame.width - expected.width) > 2 {
            state.setRatio(layout.ratio(forWidth: frame.width, isLeft: index == 0))
        }
        apply(focus: false)
    }

    // MARK: Commands

    func goTo(_ number: Int) {
        guard isRunning, StageState.numbers.contains(number) else { return }
        guard number != state.current else {
            showHUD(for: number, message: nil)
            return
        }
        transition { [weak self] in
            guard let self else { return }
            self.zoomed = nil
            self.state.goTo(number)
            self.apply()
            self.showHUD(for: number, message: nil)
        }
    }

    func back() {
        guard isRunning, let previous = state.previous else { return }
        goTo(previous)
    }

    func send(to number: Int) {
        guard isRunning, let id = focusedWindow(), number != state.current else { return }
        let joining = state[set: number].hasRoom
        state.send(id, to: number)
        apply()
        showHUD(for: number, message: joining ? "Sent to set \(number)" : "Swapped into set \(number)")
    }

    func focusOther() {
        guard isRunning, state.currentSet.windows.count == 2 else { return }
        state.focusOther()
        zoomed = nil
        apply()
    }

    func swapWindows() {
        guard isRunning else { return }
        state.swapOrder()
        apply()
    }

    func toggleLayout() {
        guard isRunning, state.currentSet.windows.count == 2 else { return }
        state.toggleLayout()
        zoomed = nil
        apply()
    }

    func toggleZoom() {
        guard isRunning, let id = focusedWindow() else { return }
        zoomed = zoomed == id ? nil : id
        apply()
    }

    func toggleFloat() {
        guard isRunning, let id = registry.frontmostFocusedWindow() else { return }
        if state.contains(id) {
            state.remove(id)
            floating.insert(id)
            apply(focus: false)
            registry.raise(id)
            HUD.show("Floating")
        } else if floating.remove(id) != nil {
            windowAppeared(id)
            HUD.show("Tiled")
        }
    }

    /// The managed window that has focus, or the current set's focused one.
    func focusedWindow() -> WindowID? {
        if let id = registry.frontmostFocusedWindow(), state.currentSet.windows.contains(id) { return id }
        return state.currentSet.focused
    }

    func replace(with other: WindowID) {
        guard isRunning, let target = focusedWindow(), target != other else { return }
        let before = state
        guard let went = state.replace(target, with: other) else { return }
        zoomed = nil
        apply()
        showReplaced(other, replaced: target, went: went, undo: before)
    }

    func replace(withApp url: URL) {
        guard isRunning, let target = focusedWindow(), let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        // Already running with a window in another set: swap that one in.
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        if let other = state.allWindows.first(where: { id in
            registry.windows[id].map { pids.contains($0.pid) } == true && !state.currentSet.windows.contains(id)
        }) {
            replace(with: other)
            return
        }
        pendingReplace = (target, bundleID, Date().addingTimeInterval(15), state)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func undo(to before: StageState) {
        guard isRunning else { return }
        var restored = before
        restored.prune(keeping: Set(registry.windows.keys))
        for id in state.allWindows where !restored.contains(id) {
            restored.add(id, activate: false)
        }
        state = restored
        apply()
        HUD.show("Undone")
    }

    func togglePin(_ bundleID: String, to number: Int) {
        if pins[bundleID] == number {
            pins[bundleID] = nil
        } else {
            pins[bundleID] = number
        }
        scheduleSave()
    }

    func unpin(_ bundleID: String) {
        pins[bundleID] = nil
        scheduleSave()
    }

    // MARK: Panels

    func armLeader() {
        guard isRunning else { return }
        leader.arm()
    }

    func showSwitcher() {
        guard isRunning, let display else { return }
        shelf.hide()
        switcher.show(on: display)
    }

    func showReplace() {
        guard isRunning, let target = focusedWindow() else {
            HUD.show("Nothing to replace")
            return
        }
        shelf.hide()
        let frame = layout.frames(for: state.currentSet, zoomed: zoomed)[target] ?? layout.single
        replacer.show(over: cocoa(frame), replacing: summary(of: target))
    }

    func showShelf() {
        guard isRunning, let display else { return }
        shelf.show(on: display)
    }

    func hideShelf() { shelf.hide() }

    // MARK: Summaries

    func summary(of id: WindowID) -> WindowSummary {
        let window = registry.windows[id]
        return WindowSummary(
            id: id,
            appName: window?.appName ?? "Window",
            title: window?.title ?? "",
            bundleID: window?.bundleID,
            icon: window?.app?.icon
        )
    }

    func summary(ofSet number: Int) -> SetSummary {
        let set = state[set: number]
        return SetSummary(
            number: number,
            windows: set.windows.map(summary(of:)),
            isSplit: set.windows.count == 2 && set.layout == .split
        )
    }

    var summaries: [SetSummary] { StageState.numbers.map(summary(ofSet:)) }

    private func showHUD(for number: Int, message: String?) {
        guard let display else { return }
        FocusHUD.show(
            FocusHUD.Content(
                number: number,
                title: summary(ofSet: number).name,
                subtitle: message ?? summary(ofSet: number).apps,
                occupied: state.occupied,
                current: state.current,
                undo: nil
            ),
            on: display
        )
    }

    private func showReplaced(_ id: WindowID, replaced: WindowID, went: Int?, undo before: StageState) {
        guard let display else { return }
        let replacedName = summary(of: replaced).appName
        FocusHUD.show(
            FocusHUD.Content(
                number: state.current,
                title: "\(summary(of: id).appName) is here",
                subtitle: went.map { "\(replacedName) moved to set \($0)" } ?? "Every set was full, so \(replacedName) floats",
                occupied: state.occupied,
                current: state.current,
                undo: { [weak self] in self?.undo(to: before) }
            ),
            on: display
        )
    }

    // MARK: Memory and saving

    private func preferredSet(for window: TrackedWindow) -> Int? {
        guard let bundleID = window.bundleID else { return nil }
        if let pinned = pins[bundleID] { return pinned }
        // Only for apps relaunching: restore where their windows were.
        guard let launched = window.app?.launchDate, Date().timeIntervalSince(launched) < 15 else { return nil }
        return memory["\(bundleID)\t\(window.title)"] ?? memory[bundleID]
    }

    private func rememberSets() {
        for number in StageState.numbers {
            for id in state[set: number].windows {
                guard let window = registry.windows[id], let bundleID = window.bundleID else { continue }
                memory["\(bundleID)\t\(window.title)"] = number
                memory[bundleID] = number
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save(active: self?.isRunning ?? false)
        }
    }

    private func save(active: Bool) {
        saveTask?.cancel()
        // Bound the memory so it can't grow forever.
        if memory.count > 500 { memory = memory.filter { !$0.key.contains("\t") } }
        FocusStore.save(FocusSnapshot(
            state: state,
            homes: homes.filter { state.contains($0.key) },
            parked: parked,
            memory: memory,
            pins: pins,
            active: active
        ))
    }
}

extension Notification.Name {
    static let featureToggled = Notification.Name("MacUtility.featureToggled")
}
