import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = Permissions()
    lazy var actions = FeatureActions(permissions: permissions)
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Hotkeys.register(actions)
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
        #endif
        if !permissions.allGranted {
            showOnboarding()
        }
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
