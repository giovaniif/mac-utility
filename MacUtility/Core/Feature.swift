import Foundation
import KeyboardShortcuts

/// A user-toggleable feature. Disabling one hides its menu items and
/// unregisters its global hotkeys.
enum Feature: String, CaseIterable, Identifiable {
    case keyboardCleaning, clipboardHistory, windowManager, focus, screenCapture

    var id: String { rawValue }

    /// UserDefaults key, read with `@AppStorage(feature.defaultsKey)`.
    var defaultsKey: String { "feature.\(rawValue).enabled" }

    var title: String {
        switch self {
        case .keyboardCleaning: "Keyboard cleaning mode"
        case .clipboardHistory: "Clipboard history"
        case .windowManager: "Move windows between displays"
        case .focus: "Focus window manager"
        case .screenCapture: "Screen capture"
        }
    }

    var shortcuts: [KeyboardShortcuts.Name] {
        switch self {
        case .keyboardCleaning: [.keyboardCleaning]
        case .clipboardHistory: [.clipboardHistory]
        case .windowManager: [.windowNextDisplay, .windowPreviousDisplay]
        case .focus: [.focusLeader, .focusSwitcher]
        case .screenCapture: [.captureArea, .captureScreen, .recordScreen]
        }
    }

    /// Focus takes over every window, so it waits to be switched on.
    var defaultEnabled: Bool { self != .focus }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultEnabled
    }

    @MainActor
    func applyHotkeys() {
        if isEnabled {
            KeyboardShortcuts.enable(shortcuts)
        } else {
            KeyboardShortcuts.disable(shortcuts)
        }
    }
}
