import KeyboardShortcuts
import SwiftUI

@main
struct MacUtilityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Mac Utility", systemImage: "wrench.and.screwdriver") {
            MenuBarContent(actions: appDelegate.actions)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(permissions: appDelegate.permissions)
        }
    }
}

/// Tray panel: switches that act right away. Feature toggles and shortcuts live in Settings.
struct MenuBarContent: View {
    let actions: FeatureActions
    @AppStorage(Feature.keyboardCleaning.defaultsKey) private var keyboardCleaning = true
    @AppStorage(Feature.screenCapture.defaultsKey) private var screenCapture = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if keyboardCleaning {
                Toggle(isOn: Binding(
                    get: { actions.keyboardCleaner.isLocked },
                    set: { _ in actions.toggleKeyboardCleaning() }
                )) {
                    Text("Keyboard cleaning").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            FeatureToggle(feature: .clipboardHistory)
            FeatureToggle(feature: .windowManager)
            FeatureToggle(feature: .screenCapture)
            if screenCapture {
                if actions.screenCapture.isRecording {
                    Toggle(isOn: Binding(
                        get: { true },
                        set: { _ in actions.toggleRecording() }
                    )) {
                        Text("Recording").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle(isOn: Binding(
                        get: { actions.screenCapture.isPaused },
                        set: { _ in actions.screenCapture.togglePause() }
                    )) {
                        Text("Paused").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .frame(width: 260)
    }
}
