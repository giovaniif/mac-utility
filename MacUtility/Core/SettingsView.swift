import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let permissions: Permissions
    let focus: FocusController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Features") {
                ForEach(Feature.allCases) { FeatureToggle(feature: $0) }
            }
            FocusSettings(focus: focus)
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Keyboard cleaning mode", name: .keyboardCleaning)
                KeyboardShortcuts.Recorder("Clipboard history", name: .clipboardHistory)
                KeyboardShortcuts.Recorder("Move window to next display", name: .windowNextDisplay)
                KeyboardShortcuts.Recorder("Move window to previous display", name: .windowPreviousDisplay)
                KeyboardShortcuts.Recorder("Capture area or window", name: .captureArea)
                KeyboardShortcuts.Recorder("Capture full screen", name: .captureScreen)
                KeyboardShortcuts.Recorder("Record screen", name: .recordScreen)
                SystemScreenshotShortcutsNotice()
            }

            Section("Permissions") {
                PermissionRows(permissions: permissions)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

struct FeatureToggle: View {
    let feature: Feature
    @AppStorage private var enabled: Bool

    init(feature: Feature) {
        self.feature = feature
        _enabled = AppStorage(wrappedValue: feature.defaultEnabled, feature.defaultsKey)
    }

    var body: some View {
        Toggle(isOn: $enabled) { Text(feature.title).frame(maxWidth: .infinity, alignment: .leading) }
            .onChange(of: enabled) {
                feature.applyHotkeys()
                NotificationCenter.default.post(name: .featureToggled, object: feature)
            }
    }
}

struct PermissionRows: View {
    let permissions: Permissions

    var body: some View {
        PermissionRow(
            title: "Accessibility",
            detail: "Arrange and move windows, and paste from clipboard history.",
            granted: permissions.accessibility,
            grant: permissions.requestAccessibility
        )
        PermissionRow(
            title: "Input Monitoring",
            detail: "Block the keyboard in cleaning mode.",
            granted: permissions.inputMonitoring,
            grant: permissions.requestInputMonitoring
        )
        PermissionRow(
            title: "Screen Recording",
            detail: "Take screenshots, record the screen, and show window previews in Focus.",
            granted: permissions.screenRecording,
            grant: permissions.requestScreenRecording
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: grant)
            }
        }
    }
}


private struct FocusSettings: View {
    let focus: FocusController
    @AppStorage("focus.widthCap") private var widthCap = 1440.0
    @AppStorage("focus.gap") private var gap = 12.0
    @AppStorage("focus.trackpadFingers") private var trackpadFingers = 3

    var body: some View {
        Section("Focus") {
            KeyboardShortcuts.Recorder("Leader key", name: .focusLeader)
            VStack(alignment: .leading) {
                KeyboardShortcuts.Recorder("Switcher", name: .focusSwitcher)
                Text("Stands in for Mission Control, which can't show parked windows well. For ⌃↑ to reach Focus, turn off Mission Control's ⌃↑ in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Picker("Trackpad swipe up", selection: $trackpadFingers) {
                    Text("Off").tag(0)
                    Text("Three fingers").tag(3)
                    Text("Four fingers").tag(4)
                }
                Text(trackpadNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Slider(value: $widthCap, in: 960...2560, step: 40) {
                    Text("Single window width")
                }
                Text("A lone window stops at \(Int(widthCap)) pt wide and centers. Split sets always use the full width.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Slider(value: $gap, in: 0...40, step: 2) {
                    Text("Gap")
                }
                Text("\(Int(gap)) pt around the stage and between two windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if focus.pins.isEmpty {
                Text("Pin an app to a set from the switcher (\(KeyboardShortcuts.Name.focusLeaderLabel) Space), with a right-click on the set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(focus.pins.sorted { $0.value < $1.value }, id: \.key) { bundleID, number in
                    HStack {
                        Text(appName(bundleID))
                        Spacer()
                        Text("Set \(number)").foregroundStyle(.secondary)
                        Button("Unpin") { focus.unpin(bundleID) }
                    }
                }
            }
            Text("Focus works best with one macOS Space per display, and doesn't run while Stage Manager is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var trackpadNote: String {
        guard trackpadFingers > 0 else { return "Swiping does nothing in Focus." }
        let key = trackpadFingers == 3 ? "TrackpadThreeFingerVertSwipeGesture" : "TrackpadFourFingerVertSwipeGesture"
        let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.AppleMultitouchTrackpad" as CFString) as? Int
        let base = "Swipe up opens the switcher, swipe down closes it."
        guard value == 2 else { return base }
        return base + " macOS still uses this swipe for Mission Control, so both would open: turn off Mission Control in System Settings → Trackpad → More Gestures."
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
