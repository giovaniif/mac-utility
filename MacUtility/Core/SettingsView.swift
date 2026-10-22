import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let permissions: Permissions
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
        _enabled = AppStorage(wrappedValue: true, feature.defaultsKey)
    }

    var body: some View {
        Toggle(isOn: $enabled) { Text(feature.title).frame(maxWidth: .infinity, alignment: .leading) }
            .onChange(of: enabled) { feature.applyHotkeys() }
    }
}

struct PermissionRows: View {
    let permissions: Permissions

    var body: some View {
        PermissionRow(
            title: "Accessibility",
            detail: "Move windows and paste from clipboard history.",
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
            detail: "Take screenshots and record the screen.",
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

