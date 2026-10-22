import AppKit
import Combine
import SwiftUI

/// The built-in macOS screenshot shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5 and their
/// clipboard variants). While they're on, macOS gets those keys first.
enum SystemScreenshotShortcuts {
    /// IDs in `com.apple.symbolichotkeys`.
    private static let ids = ["28", "29", "30", "31", "184"]

    /// True if any of them is still on. Missing entries mean the macOS default, which is on.
    static var anyEnabled: Bool {
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return ids.contains { id in
            guard let entry = hotkeys?[id] as? [String: Any] else { return true }
            return (entry["enabled"] as? Bool) ?? true
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
    }
}

/// Settings row that shows up only while macOS still owns the screenshot keys.
struct SystemScreenshotShortcutsNotice: View {
    @State private var enabled = SystemScreenshotShortcuts.anyEnabled
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if enabled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("macOS screenshot shortcuts are on")
                        Text("Turn off everything under Screenshots so ⇧⌘3, ⇧⌘4 and ⇧⌘5 reach Mac Utility.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open…", action: SystemScreenshotShortcuts.openSettings)
                }
            }
        }
        .onReceive(timer) { _ in enabled = SystemScreenshotShortcuts.anyEnabled }
    }
}
