import AppKit
import ApplicationServices
import os

/// One top-level window of another app, as Accessibility sees it.
struct TrackedWindow {
    let id: WindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let element: AXUIElement

    var title: String { element.string(kAXTitleAttribute) ?? "" }
    var frame: CGRect? { element.frame }
    var isMinimized: Bool { element.bool(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { element.bool("AXFullScreen") ?? false }
    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
}

/// Follows every regular app's windows through one AXObserver per app plus
/// NSWorkspace notifications, and reports what changed.
@MainActor
final class WindowRegistry {
    enum Event {
        case appeared(WindowID)
        case disappeared(WindowID)
        case focused(WindowID)
        case minimized(WindowID)
        case restored(WindowID)
        case moved(WindowID)
        case resized(WindowID)
        case appHidden(pid_t)
        case appShown(pid_t)
    }

    var onEvent: (Event) -> Void = { _ in }
    private(set) var windows: [WindowID: TrackedWindow] = [:]

    private let log = Logger(subsystem: "com.giovani.MacUtility", category: "focus")
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { handler(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in self?.watchSoon(app) }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in self?.forget(app.processIdentifier) }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in self?.onEvent(.appHidden(app.processIdentifier)) }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in self?.onEvent(.appShown(app.processIdentifier)) }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self else { return }
            // Pick up windows that appeared before the observer was ready.
            self.scan(app)
            if let id = self.focusedWindow(of: app.processIdentifier) { self.onEvent(.focused(id)) }
        }
        for app in NSWorkspace.shared.runningApplications { watch(app) }
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        windows.removeAll()
    }

    /// Windows of every watched app, front to back as the window server
    /// orders them on screen.
    func windowsFrontToBack() -> [TrackedWindow] {
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? WindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return windows.values.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    func focusedWindow(of pid: pid_t) -> WindowID? {
        AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute)?.windowID
    }

    func frontmostFocusedWindow() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindow(of: app.processIdentifier)
    }

    /// Brings a window to the front and makes its app active, through
    /// Accessibility: a background app can't activate others with AppKit.
    func raise(_ id: WindowID) {
        guard let window = windows[id] else { return }
        window.element.set(kAXMainAttribute, bool: true)
        window.element.perform(kAXRaiseAction)
        AXUIElementCreateApplication(window.pid).set(kAXFrontmostAttribute, bool: true)
    }

    // MARK: Watching

    private func watchSoon(_ app: NSRunningApplication) {
        watch(app)
        // A launching app often isn't ready for Accessibility yet.
        for delay in [0.3, 1.0, 2.5] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.watch(app)
                self?.scan(app)
            }
        }
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ownPID, !app.isTerminated, observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var ok = false
        for name in Self.appNotifications {
            ok = AXObserverAddNotification(observer, appElement, name as CFString, refcon) == .success || ok
        }
        // Not ready yet (or not an AX citizen): try again on a later scan.
        guard ok else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        scan(app)
    }

    private func scan(_ app: NSRunningApplication) {
        guard observers[app.processIdentifier] != nil else { return }
        for element in AXUIElementCreateApplication(app.processIdentifier).elements(kAXWindowsAttribute) {
            track(element, app: app)
        }
    }

    private func track(_ element: AXUIElement, app: NSRunningApplication) {
        guard element.string(kAXRoleAttribute) == kAXWindowRole,
              let id = element.windowID, windows[id] == nil,
              let observer = observers[app.processIdentifier] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        windows[id] = TrackedWindow(
            id: id,
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "App",
            element: element
        )
        onEvent(.appeared(id))
    }

    private func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        for (id, window) in windows where window.pid == pid {
            windows[id] = nil
            onEvent(.disappeared(id))
        }
    }

    private func id(of element: AXUIElement) -> WindowID? {
        if let id = element.windowID, windows[id] != nil { return id }
        // Destroyed windows no longer answer; match the element instead.
        return windows.values.first { CFEqual($0.element, element) }?.id
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            guard let pid = element.pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
            track(element, app: app)
        case kAXFocusedWindowChangedNotification:
            if let window = element.string(kAXRoleAttribute) == kAXWindowRole ? element : element.element(kAXFocusedWindowAttribute),
               let id = id(of: window) {
                onEvent(.focused(id))
            }
        case kAXUIElementDestroyedNotification:
            guard let id = id(of: element) else { return }
            windows[id] = nil
            onEvent(.disappeared(id))
        case kAXWindowMiniaturizedNotification:
            if let id = id(of: element) { onEvent(.minimized(id)) }
        case kAXWindowDeminiaturizedNotification:
            if let id = id(of: element) { onEvent(.restored(id)) }
        case kAXWindowMovedNotification:
            if let id = id(of: element) { onEvent(.moved(id)) }
        case kAXWindowResizedNotification:
            if let id = id(of: element) { onEvent(.resized(id)) }
        default:
            break
        }
    }
}

/// Runs on the main run loop, where the observers' sources are added.
private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let registry = Unmanaged<WindowRegistry>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated {
        registry.handle(name, element: element)
    }
}
