import AppKit
import ApplicationServices
import KeyboardShortcuts
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
    var ratio = 0.5
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
    @ObservationIgnored private lazy var statusItem = SetsStatusItem(controller: self)

    @ObservationIgnored private var homes: [WindowID: CGRect] = [:]
    @ObservationIgnored private var parked: Set<WindowID> = []
    @ObservationIgnored private var memory: [String: Int] = [:]
    /// Floated by the user with the leader's `\`.
    @ObservationIgnored private var floating: Set<WindowID> = []
    /// Popups, sign-in and settings windows: classified once, when first
    /// seen, so a later resize doesn't pull them into a set.
    @ObservationIgnored private var popups: Set<WindowID> = []
    @ObservationIgnored private var seen: Set<WindowID> = []
    /// While the screen is locked displays come and go; leave windows alone.
    @ObservationIgnored private var locked = false
    /// Didn't fit anywhere: every set was full.
    @ObservationIgnored private var overflow: Set<WindowID> = []
    /// Minimized or hidden windows and the set they come back to.
    @ObservationIgnored private var away: [WindowID: Int] = [:]
    @ObservationIgnored private var ownChangeUntil: [WindowID: Date] = [:]
    @ObservationIgnored private var focusMutedUntil = Date.distantPast
    @ObservationIgnored private var zoomed: WindowID?
    @ObservationIgnored private var pendingReplace: (target: WindowID, bundleID: String, until: Date, before: StageState)?
    /// A split opened with the leader's v/s whose second pane is still empty:
    /// the picker is up, or an app is opening the window that goes there.
    @ObservationIgnored private var openSplit: SplitAxis?
    @ObservationIgnored private var pendingSplit: (bundleID: String, until: Date)?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var adopting = false
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var appliedWidthCap = 0.0
    @ObservationIgnored private var appliedGap = -1.0
    @ObservationIgnored private var trackpadFingers = 0

    /// Never tiled: utility apps whose windows are fixed panels at heart.
    private static let floatingApps: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.finder",
        "com.apple.calculator",
        "com.apple.archiveutility",
        "com.apple.ScreenSharing",
        "com.apple.PhotoBooth",
    ]

    static var widthCap: Double {
        let stored = UserDefaults.standard.double(forKey: "focus.widthCap")
        return stored > 0 ? stored : 1440
    }

    /// Fingers for the switcher's trackpad swipe; 0 is off.
    static var trackpadFingers: Int {
        guard UserDefaults.standard.object(forKey: "focus.trackpadFingers") != nil else { return 3 }
        let value = UserDefaults.standard.integer(forKey: "focus.trackpadFingers")
        return [0, 3, 4].contains(value) ? value : 3
    }

    /// Space around and between windows on the stage, 0–40 pt.
    static var gap: Double {
        guard UserDefaults.standard.object(forKey: "focus.gap") != nil else { return 12 }
        return min(max(UserDefaults.standard.double(forKey: "focus.gap"), 0), 40)
    }

    init(permissions: Permissions) {
        self.permissions = permissions
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .featureToggled, object: nil, queue: .main) { note in
            guard let feature = note.object as? Feature, feature == .focus else { return }
            MainActor.assumeIsolated { [weak self] in self?.syncWithFeature() }
        })
        let distributed = DistributedNotificationCenter.default()
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.locked = true }
        })
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.recoverAfterLock() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, !self.locked else { return }
                self.recoverAfterLock()
            }
        })
        tokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.apply(focus: false) }
        })
        tokens.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isRunning else { return }
                if Self.trackpadFingers != self.trackpadFingers { self.startTrackpad() }
                guard Self.widthCap != self.appliedWidthCap || Self.gap != self.appliedGap else { return }
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
        statusItem.show()
        startTrackpad()
        apply(focus: true)
        log.notice("focus started with \(self.state.allWindows.count) windows")
    }

    /// Lock and sleep drop the Accessibility observers and the trackpad
    /// devices; rebuild both and put the stage back.
    private func recoverAfterLock() {
        locked = false
        guard isRunning else { return }
        adopting = true
        registry.stop()
        registry.start()
        adopting = false
        adoptAll()
        startTrackpad()
        apply(focus: false)
        log.notice("focus recovered after lock with \(self.state.allWindows.count) windows")
    }

    /// Brings every parked window back to where it last was on the stage.
    func stop() {
        guard isRunning else { return }
        leader.disarm()
        switcher.hide()
        replacer.hide()
        // A half-open split gives its window the whole stage back first.
        if openSplit != nil {
            openSplit = nil
            pendingSplit = nil
            apply(focus: false)
        }
        shelf.stopWatchingPointer()
        shelf.hide()
        TrackpadSwipe.shared.stop()
        trackpadFingers = 0
        statusItem.hide()
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

    /// Swipe up opens the switcher, swipe down closes it, like Mission Control.
    private func startTrackpad() {
        trackpadFingers = Self.trackpadFingers
        guard trackpadFingers > 0 else {
            TrackpadSwipe.shared.stop()
            return
        }
        TrackpadSwipe.shared.start(fingers: trackpadFingers) { [weak self] direction in
            guard let self, self.isRunning else { return }
            switch direction {
            case .up where !self.switcher.isVisible: self.showSwitcher()
            case .down where self.switcher.isVisible: self.switcher.hide()
            default: break
            }
        }
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
        StageLayout(stage: ax(display?.visibleFrame ?? .zero), gap: CGFloat(Self.gap), widthCap: CGFloat(Self.widthCap))
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
        guard !floating.contains(window.id), !isPopup(window), !window.isMinimized, !window.isFullScreen,
              window.app?.isHidden != true,
              window.element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
              window.element.isSettable(kAXSizeAttribute), window.element.isSettable(kAXPositionAttribute),
              let frame = window.frame, frame.width >= 200, frame.height >= 150 else { return false }
        return true
    }

    private func isPopup(_ window: TrackedWindow) -> Bool {
        if seen.insert(window.id).inserted, classifyPopup(window) { popups.insert(window.id) }
        return popups.contains(window.id)
    }

    /// Finder, System Settings, app settings windows, sign-in and web popups
    /// (a Meet popover, an OAuth window) float above the stage instead.
    private func classifyPopup(_ window: TrackedWindow) -> Bool {
        if let bundleID = window.bundleID, Self.floatingApps.contains(bundleID) { return true }
        let element = window.element
        if element.bool("AXModal") == true { return true }
        // Settings and auth windows can't zoom or go full screen.
        guard let zoom = element.element(kAXZoomButtonAttribute), zoom.bool(kAXEnabledAttribute) != false,
              element.element(kAXFullScreenButtonAttribute) != nil else { return true }
        // A small extra window from an app that already has one tiled.
        if let frame = window.frame, frame.width < 1000 || frame.height < 700,
           registry.windows.values.contains(where: { $0.pid == window.pid && $0.id != window.id && state.contains($0.id) }) {
            return true
        }
        return false
    }

    // MARK: Placing windows

    /// Moves real windows to match `state`: the current set on the stage,
    /// everything else parked. `focus` raises the set's focused window.
    func apply(focus: Bool = true) {
        guard isRunning, !locked else { return }
        log.debug("trace apply focus \(focus) current \(self.state.current)")
        let set = state.currentSet
        appliedWidthCap = Self.widthCap
        appliedGap = Self.gap
        let frames = stageFrames()
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
        let upcoming = nextFrames()
        for id in state.allWindows where frames[id] == nil { park(id, size: upcoming[id]?.size) }
        rememberSets()
        scheduleSave()
    }

    /// The current set's frames; while a split waits for its second window,
    /// the one window keeps the first pane.
    private func stageFrames() -> [WindowID: CGRect] {
        let set = state.currentSet
        if let axis = openSplit, set.windows.count == 1, let only = set.windows.first {
            return [only: layout.split(ratio: set.ratio, axis: axis).0]
        }
        return layout.frames(for: set, zoomed: zoomed)
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

    /// Where every parked window will sit when its set is next on stage.
    private func nextFrames() -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        for number in StageState.numbers {
            let set = state[set: number]
            frames.merge(layout.frames(for: set)) { current, _ in current }
            // The hidden half of a stacked set comes back at full stage size.
            for id in set.windows where frames[id] == nil { frames[id] = layout.single }
        }
        return frames
    }

    /// Parks a window in the corner, already at the size it will have when
    /// it's next shown. It then comes back without resizing on screen, and
    /// its picture in the slide matches its box instead of being stretched.
    private func park(_ id: WindowID, size: CGSize? = nil) {
        guard let window = registry.windows[id], let frame = window.frame else { return }
        let target = size ?? frame.size
        let others = NSScreen.screens.dropFirst().map { ax($0.frame) }
        let origin = StageLayout.parkingOrigin(size: target, display: displayRect, otherDisplays: others)
        if !parked.contains(id), displayRect.intersects(frame) { homes[id] = frame }
        parked.insert(id)
        let moves = abs(frame.minX - origin.x) >= 1 || abs(frame.minY - origin.y) >= 1
        let resizes = abs(frame.width - target.width) >= 1 || abs(frame.height - target.height) >= 1
        guard moves || resizes else { return }
        markOwnChange(id)
        // Off screen first, then resize, so the resize is never seen.
        if moves { window.element.set(kAXPositionAttribute, point: origin) }
        if resizes { window.element.set(kAXSizeAttribute, size: target) }
    }

    private func markOwnChange(_ id: WindowID) {
        ownChangeUntil[id] = Date().addingTimeInterval(0.6)
    }

    /// Switch sets with a Spaces-style slide (skipped with Reduce Motion or
    /// no Screen Recording). The snapshot also feeds the cards' thumbnails.
    /// Switch sets behind the switch animation (a short fade, or none).
    private func transition(to number: Int, _ change: @escaping () -> Void) {
        log.debug("trace transition to \(number) from \(self.state.current)")
        guard let display else {
            change()
            return
        }
        motion.transition(on: display, outgoing: stageFrames().mapValues(cocoa)) { [weak self] shots in
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
            if let window = registry.windows[id], !state.contains(id), isPopup(window) {
                // Popups open on top of the stage, after any re-tiling.
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    self?.registry.raise(id)
                }
                return
            }
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

        if let pending = pendingSplit, pending.bundleID == window.bundleID, Date() < pending.until, let axis = openSplit {
            pendingSplit = nil
            openSplit = nil
            if state.pullInNew(id, axis: axis) {
                apply()
            } else {
                add(id, preferred: nil, activate: true)
            }
            return
        }
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
            // Only worth a word when the window didn't land where you were.
            if switched, becauseFull {
                showHUD(for: number, message: "Set \(state.previous ?? number) already had two windows. \(KeyboardShortcuts.Name.focusLeaderLabel) ⇥ goes back.")
            }
        case .unmanaged:
            overflow.insert(id)
            HUD.show("Every set is full")
        }
    }

    private func windowGone(_ id: WindowID) {
        floating.remove(id)
        popups.remove(id)
        seen.remove(id)
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
        log.debug("trace focus \(id) muted \(Date() <= self.focusMutedUntil) set \(self.state.setNumber(of: id) ?? -1) current \(self.state.current)")
        guard Date() > focusMutedUntil, state.contains(id) else { return }
        let changed = state.focus(id)
        if changed {
            // ⌘Tab or a Dock click on a parked window: the stage follows it.
            zoomed = nil
            apply(focus: false)
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
           abs(frame.width - expected.width) > 2 || abs(frame.height - expected.height) > 2 {
            state.setRatio(layout.ratio(for: frame.size, isFirst: index == 0, axis: set.axis))
        }
        apply(focus: false)
    }

    // MARK: Commands

    func goTo(_ number: Int) {
        guard isRunning, StageState.numbers.contains(number) else { return }
        guard number != state.current else { return }
        transition(to: number) { [weak self] in
            guard let self else { return }
            self.zoomed = nil
            self.state.goTo(number)
            // No card here: the stage itself and the menu bar numbers show where you are.
            self.apply()
        }
    }

    func back() {
        guard isRunning, let previous = state.previous else { return }
        goTo(previous)
    }

    /// Leader ⇧1–9: the focused window moves to that set and you go with it.
    func send(to number: Int) {
        guard isRunning, StageState.numbers.contains(number), number != state.current,
              let id = focusedWindow() else { return }
        state.send(id, to: number)
        state[set: number].focused = id
        zoomed = nil
        openSplit = nil
        transition(to: number) { [weak self] in
            guard let self else { return }
            self.state.goTo(number)
            self.apply()
        }
    }

    // MARK: Splits, vim style

    /// Leader v or s. One window: split now, with the picker in the empty
    /// pane. Two: just turn the split that way.
    func split(_ axis: SplitAxis) {
        guard isRunning else { return }
        let set = state.currentSet
        zoomed = nil
        if set.windows.count == 2 {
            state.setAxis(axis)
            apply()
            return
        }
        guard let focused = set.focused ?? set.windows.first else {
            // Nothing to split on an empty set: offer to open something.
            showOpen()
            return
        }
        shelf.hide()
        state.currentSet.ratio = 0.5
        openSplit = axis
        pendingSplit = nil
        apply(focus: false)
        let (_, empty) = layout.split(ratio: 0.5, axis: axis)
        replacer.showSplit(over: cocoa(empty), beside: summary(of: focused), axis: axis)
    }

    /// Esc in the picker: the window takes the whole stage again.
    func cancelSplit() {
        guard openSplit != nil else { return }
        openSplit = nil
        pendingSplit = nil
        apply()
    }

    func split(with other: WindowID) {
        guard let axis = openSplit else { return }
        openSplit = nil
        state.pullIn(other, axis: axis)
        apply()
    }

    /// A running app: its window in another set moves here, or it's asked for
    /// a new window, which takes the empty pane when it shows up.
    func split(withApp url: URL) {
        guard openSplit != nil, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        if let other = state.allWindows.first(where: { id in
            registry.windows[id].map { pids.contains($0.pid) } == true && !state.currentSet.windows.contains(id)
        }) {
            split(with: other)
            return
        }
        pendingSplit = (bundleID, Date().addingTimeInterval(15))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.pendingSplit?.bundleID == bundleID else { return }
            // No window came: give the stage back to the one that's there.
            self.cancelSplit()
        }
    }

    /// Leader t: flip the split between side by side and top and bottom.
    func toggleAxis() {
        guard isRunning, state.toggleAxis() else { return }
        zoomed = nil
        apply()
    }

    /// Leader o, like vim's Ctrl-w o: keep the focused window alone.
    func only() {
        guard isRunning, let other = state.currentSet.unfocused else { return }
        let name = summary(of: other).appName
        guard let went = state.only() else {
            HUD.show("No free set for \(name)")
            return
        }
        zoomed = nil
        apply()
        showHUD(for: went, message: "\(name) moved to set \(went)")
    }

    /// Leader h/j/k/l or arrows: the pane that way, like vim's Ctrl-w h/j/k/l.
    func focusPane(_ direction: PaneDirection) {
        guard isRunning else { return }
        syncFocus()
        if state.currentSet.layout == .stacked {
            focusOther()
            return
        }
        if state.focusPane(direction) {
            zoomed = nil
            apply()
        } else if let focused = state.currentSet.focused, registry.frontmostFocusedWindow() != focused {
            // Already that pane in our books, but not on screen: give it focus.
            registry.raise(focused)
        }
    }

    /// Our record of the focused pane can drift from the real one (focus
    /// events are ignored for a moment after Focus moves windows), so take
    /// the real one before acting on it.
    private func syncFocus() {
        guard let actual = registry.frontmostFocusedWindow(), state.currentSet.windows.contains(actual) else { return }
        state.currentSet.focused = actual
    }

    func focusOther() {
        guard isRunning, state.currentSet.windows.count == 2 else { return }
        syncFocus()
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
        } else if popups.remove(id) != nil {
            add(id, preferred: nil, activate: true)
            HUD.show("Tiled")
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

    #if DEBUG
    func debugTrayClick(index: Int) { statusItem.debugClick(index: index) }

    func debugFreeze() {
        if let display { motion.debugFreeze(on: display) }
    }
    #endif

    func armLeader() {
        guard isRunning else { return }
        motion.prefetch()
        leader.arm()
    }

    /// Fresh thumbnails of every managed window, parked ones included.
    private func refreshThumbnails() {
        motion.snapshots(of: state.allWindows) { [weak self] id, image in
            self?.thumbnails[id] = image
        }
    }

    func showSwitcher() {
        guard isRunning, let display else { return }
        refreshThumbnails()
        leader.disarm()
        // Same key again closes it, like Mission Control.
        if switcher.isVisible {
            switcher.hide()
            return
        }
        shelf.hide()
        switcher.show(on: display)
    }

    func showReplace() {
        guard isRunning else { return }
        guard let target = focusedWindow() else {
            showOpen()
            return
        }
        shelf.hide()
        let frame = layout.frames(for: state.currentSet, zoomed: zoomed)[target] ?? layout.single
        replacer.show(over: cocoa(frame), replacing: summary(of: target))
    }

    /// An empty set: the picker over the whole stage, search ready.
    func showOpen() {
        guard isRunning else { return }
        shelf.hide()
        replacer.showOpen(over: cocoa(layout.inner))
    }

    /// Picker on an empty set: bring a window from another set here.
    func open(_ id: WindowID) {
        guard isRunning, state.currentSet.hasRoom, let from = state.setNumber(of: id), from != state.current else { return }
        state.remove(id)
        state.currentSet.insert(id)
        state.currentSet.focused = id
        apply()
    }

    /// Picker on an empty set: an app. Its window in another set comes here;
    /// otherwise it's opened, and its new window joins this set by the
    /// new-window rule.
    func open(app url: URL) {
        guard isRunning, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        if let other = state.allWindows.first(where: { id in registry.windows[id].map { pids.contains($0.pid) } == true }) {
            open(other)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func showShelf() {
        guard isRunning, let display else { return }
        refreshThumbnails()
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
            isSplit: set.windows.count == 2 && set.layout == .split,
            ratio: set.ratio
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
