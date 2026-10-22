import Foundation
import KeyboardShortcuts

/// A user-toggleable feature. Disabling one hides its menu items and
/// unregisters its global hotkeys.
enum Feature: String, CaseIterable, Identifiable {
    case keyboardCleaning, clipboardHistory, windowManager

    var id: String { rawValue }

    /// UserDefaults key, read with `@AppStorage(feature.defaultsKey)`.
    var defaultsKey: String { "feature.\(rawValue).enabled" }

    var title: String {
        switch self {
        case .keyboardCleaning: "Keyboard cleaning mode"
        case .clipboardHistory: "Clipboard history"
        case .windowManager: "Window manager"
        }
    }

    var shortcuts: [KeyboardShortcuts.Name] {
        switch self {
        case .keyboardCleaning: [.keyboardCleaning]
        case .clipboardHistory: [.clipboardHistory]
        case .windowManager: [.windowNextDisplay, .windowPreviousDisplay]
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
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
