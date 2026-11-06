import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = Permissions()
    lazy var actions = FeatureActions(permissions: permissions)
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Hotkeys.register(actions)
        // Starts Focus, or brings back windows a crashed session left parked.
        actions.focus.syncWithFeature()
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "testPreview") {
            actions.screenCapture.showTestPreview(URL(fileURLWithPath: path))
        }
        if let path = UserDefaults.standard.string(forKey: "testEditorRender") {
            ScreenshotEditor.renderSample(URL(fileURLWithPath: path), to: URL(fileURLWithPath: path + ".out.png"))
        }
        if let path = UserDefaults.standard.string(forKey: "testEditor") {
            actions.screenCapture.openTestEditor(URL(fileURLWithPath: path))
        }
        if UserDefaults.standard.bool(forKey: "testCaptureScreen") {
            actions.screenCapture.captureScreen()
        }
        if UserDefaults.standard.bool(forKey: "testFocusSwitcher") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                actions.focus.showSwitcher()
            }
        }
        if UserDefaults.standard.bool(forKey: "testFocusCycle") {
            Task {
                for number in [2, 3, 1, 4, 2] {
                    try? await Task.sleep(for: .seconds(1.2))
                    actions.focus.goTo(number)
                }
            }
        }
        if UserDefaults.standard.integer(forKey: "testFocusSend") > 0 {
            Task {
                try? await Task.sleep(for: .seconds(2))
                actions.focus.goTo(1)
                try? await Task.sleep(for: .seconds(1.5))
                actions.focus.send(to: UserDefaults.standard.integer(forKey: "testFocusSend"))
            }
        }
        if UserDefaults.standard.bool(forKey: "testFocusLeader") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                actions.focus.armLeader()
            }
        }
        if UserDefaults.standard.bool(forKey: "testFocusCarry") {
            Task {
                let focus = actions.focus
                try? await Task.sleep(for: .seconds(2))
                focus.goTo(1)
                try? await Task.sleep(for: .seconds(1))
                focus.split(.vertical)
                try? await Task.sleep(for: .seconds(0.5))
                if let from = focus.state.occupied.first(where: { $0 != 1 }),
                   let other = focus.state[set: from].windows.first {
                    focus.split(with: other)
                }
                try? await Task.sleep(for: .seconds(1.5))
                if let empty = focus.state.lowestEmpty(excluding: 1) { focus.send(to: empty) }
            }
        }
        if UserDefaults.standard.bool(forKey: "testFocusSplit") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                actions.focus.split(.vertical)
            }
        }
        if UserDefaults.standard.bool(forKey: "testFocusReplace") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                actions.focus.showReplace()
            }
        }
        #endif
        // Only on first launch; after that Settings shows the same rows.
        if !UserDefaults.standard.bool(forKey: "onboardingShown"), !permissions.allGranted {
            UserDefaults.standard.set(true, forKey: "onboardingShown")
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        actions.focus.stop()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(permissions: permissions) { [weak self] in
                self?.onboardingWindow?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Mac Utility"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
