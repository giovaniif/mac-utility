import os

enum DisplayDirection {
    case next, previous
}

/// Entry points shared by the menu and global hotkeys. Each feature service
/// plugs in here as it gets built.
@MainActor
final class FeatureActions {
    private let log = Logger(subsystem: "com.giovani.MacUtility", category: "actions")
    private let windowMover: WindowMover
    let keyboardCleaner: KeyboardCleaner
    private let clipboardHistory: ClipboardHistory
    let screenCapture: ScreenCapture

    init(permissions: Permissions) {
        windowMover = WindowMover(permissions: permissions)
        keyboardCleaner = KeyboardCleaner(permissions: permissions)
        clipboardHistory = ClipboardHistory(permissions: permissions)
        screenCapture = ScreenCapture(permissions: permissions)
    }

    func toggleKeyboardCleaning() {
        guard Feature.keyboardCleaning.isEnabled else { return }
        keyboardCleaner.toggle()
    }

    func showClipboardHistory() {
        guard Feature.clipboardHistory.isEnabled else { return }
        clipboardHistory.toggle()
    }

    func moveWindow(_ direction: DisplayDirection) {
        guard Feature.windowManager.isEnabled else { return }
        windowMover.move(direction)
    }

    func captureArea() {
        guard Feature.screenCapture.isEnabled else { return }
        screenCapture.captureArea()
    }

    func captureScreen() {
        guard Feature.screenCapture.isEnabled else { return }
        screenCapture.captureScreen()
    }

    func toggleRecording() {
        guard Feature.screenCapture.isEnabled else { return }
        screenCapture.toggleRecording()
    }
}
