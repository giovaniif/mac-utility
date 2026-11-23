import AppKit
import ApplicationServices
import os

/// The terminal that leader ↩ shows and hides and leader ⇧↩ opens a new
/// window of. Settings → Focus picks one; Automatic takes the first known
/// terminal that's running, else the first one installed.
enum TerminalApp {
    struct Known: Identifiable, Sendable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// In the order Automatic tries them.
    static let known: [Known] = [
        Known(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        Known(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        Known(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
        Known(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        Known(bundleID: "org.alacritty", name: "Alacritty"),
        Known(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        Known(bundleID: "co.zeit.hyper", name: "Hyper"),
        Known(bundleID: "org.tabby", name: "Tabby"),
        Known(bundleID: "com.raphaelamorim.rio", name: "Rio"),
        Known(bundleID: "com.apple.Terminal", name: "Terminal"),
    ]

    /// Settings → Focus → Terminal; empty is Automatic.
    static let defaultsKey = "focus.terminal"

    private static let log = Logger(subsystem: "com.giovani.MacUtility", category: "focus")

    static var installed: [Known] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// The bundle ID of the terminal to use, nil when none is installed.
    static var preferred: String? {
        let chosen = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if !chosen.isEmpty, NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) != nil { return chosen }
        let installed = installed
        return installed.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }?.bundleID
            ?? installed.first?.bundleID
    }

    /// Whether windows of this app count as a terminal for the toggle.
    static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == preferred || known.contains { $0.bundleID == bundleID }
    }

    /// Asks the terminal for a new window: launches it if it isn't running
    /// (it opens one by itself), otherwise presses its ⌘N menu item through
    /// Accessibility, or types ⌘N when the menu doesn't have one.
    /// Returns false when there's no terminal to open.
    @discardableResult
    static func openWindow(_ bundleID: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) {
            let pid = app.processIdentifier
            if pressNewWindow(pid) { return true }
            log.notice("focus: no ⌘N menu item in \(bundleID, privacy: .public), typing it")
            AXUIElementCreateApplication(pid).set(kAXFrontmostAttribute, bool: true)
            Task {
                // Key equivalents go to the active app; give it a moment.
                try? await Task.sleep(for: .milliseconds(150))
                postCommandN(to: pid)
            }
            return true
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    /// File → New Window in every terminal here is ⌘N (Terminal keeps it
    /// one level down, in Shell → New Window). Found by its shortcut, not
    /// its title, so it works in any language.
    private static func pressNewWindow(_ pid: pid_t) -> Bool {
        guard let menuBar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { return false }
        // Skip the Apple menu and the app menu: ⌘N there would be odd.
        for barItem in menuBar.elements(kAXChildrenAttribute).dropFirst(2) {
            for menu in barItem.elements(kAXChildrenAttribute) {
                if let item = commandN(in: menu, depth: 2) {
                    item.perform(kAXPressAction)
                    return true
                }
            }
        }
        return false
    }

    private static func commandN(in menu: AXUIElement, depth: Int) -> AXUIElement? {
        for item in menu.elements(kAXChildrenAttribute) {
            if item.string(kAXMenuItemCmdCharAttribute)?.uppercased() == "N",
               (item.value(kAXMenuItemCmdModifiersAttribute) as? Int) == 0,
               item.bool(kAXEnabledAttribute) != false {
                return item
            }
            guard depth > 0 else { continue }
            for submenu in item.elements(kAXChildrenAttribute) {
                if let found = commandN(in: submenu, depth: depth - 1) { return found }
            }
        }
        return nil
    }

    private static func postCommandN(to pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let n: CGKeyCode = 45
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: n, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
    }
}
