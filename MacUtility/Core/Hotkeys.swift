import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let keyboardCleaning = Self("keyboardCleaning", default: .init(.k, modifiers: [.control, .option, .command]))
    static let clipboardHistory = Self("clipboardHistory", default: .init(.v, modifiers: [.shift, .command]))
    static let windowNextDisplay = Self("windowNextDisplay", default: .init(.rightArrow, modifiers: [.control, .command]))
    static let windowPreviousDisplay = Self("windowPreviousDisplay", default: .init(.leftArrow, modifiers: [.control, .command]))
}

@MainActor
enum Hotkeys {
    static func register(_ actions: FeatureActions) {
        KeyboardShortcuts.onKeyUp(for: .keyboardCleaning) { actions.toggleKeyboardCleaning() }
        KeyboardShortcuts.onKeyUp(for: .clipboardHistory) { actions.showClipboardHistory() }
        KeyboardShortcuts.onKeyUp(for: .windowNextDisplay) { actions.moveWindow(.next) }
        KeyboardShortcuts.onKeyUp(for: .windowPreviousDisplay) { actions.moveWindow(.previous) }
        Feature.allCases.forEach { $0.applyHotkeys() }
    }
}
