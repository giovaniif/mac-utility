import AppKit
import ApplicationServices
import os

/// Everything Focus keeps on disk. Written on every change, so a crash
/// leaves enough behind to bring parked windows back.
struct FocusSnapshot: Codable {
    var state = StageState()
    /// Last on-stage frame of each window, in Accessibility coordinates.
    var homes: [WindowID: CGRect] = [:]
    var parked: Set<WindowID> = []
    /// "bundleID\ttitle" and "bundleID" → set, for apps that relaunch.
    var memory: [String: Int] = [:]
    /// bundleID → set: new windows of a pinned app go there.
    var pins: [String: Int] = [:]
    /// True while Focus runs. Still true at launch means it didn't stop cleanly.
    var active = false
}

@MainActor
enum FocusStore {
    private static let log = Logger(subsystem: "com.giovani.MacUtility", category: "focus")

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MacUtility/focus-state.json")
    }

    static func load() -> FocusSnapshot {
        guard let data = try? Data(contentsOf: url) else { return FocusSnapshot() }
        do {
            return try JSONDecoder().decode(FocusSnapshot.self, from: data)
        } catch {
            log.error("couldn't read focus state: \(error.localizedDescription)")
            return FocusSnapshot()
        }
    }

    static func save(_ snapshot: FocusSnapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            log.error("couldn't save focus state: \(error.localizedDescription)")
        }
    }

    /// Focus isn't going to run (switched off, or no permission) but the last
    /// session left windows parked: put each one back where it last was.
    static func recoverIfNeeded() {
        var snapshot = load()
        guard snapshot.active else { return }
        log.notice("recovering \(snapshot.parked.count) parked windows")
        if AXIsProcessTrusted() {
            let fallback = NSScreen.screens.first.map { ScreenGeometry.flip($0.visibleFrame, primaryHeight: $0.frame.height) }
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                for window in AXUIElementCreateApplication(app.processIdentifier).elements(kAXWindowsAttribute) {
                    guard let id = window.windowID, snapshot.parked.contains(id) else { continue }
                    if let home = snapshot.homes[id] {
                        window.setFrame(home)
                    } else if let fallback, let size = window.size(kAXSizeAttribute) {
                        window.setFrame(ScreenGeometry.center(CGRect(origin: .zero, size: size), in: fallback))
                    }
                }
            }
        }
        snapshot.parked.removeAll()
        snapshot.active = false
        save(snapshot)
    }
}

/// Stage Manager moves windows on its own and fights any window manager.
@MainActor
enum StageManager {
    static var isEnabled: Bool {
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        return (value as? Bool) ?? false
    }

    static func explain() {
        let alert = NSAlert()
        alert.messageText = "Turn off Stage Manager to use Focus"
        alert.informativeText = "Stage Manager arranges windows on its own, so it and Focus would keep moving the same windows. Turn it off in Desktop & Dock, then switch Focus on again."
        alert.addButton(withTitle: "Open Desktop & Dock")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
