import AppKit
import SwiftUI

/// First-launch window: what each permission unlocks, its live status, and a
/// button to grant it.
struct OnboardingView: View {
    let permissions: Permissions
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Mac Utility")
                        .font(.title2.bold())
                    Text("Everything runs from the menu bar icon. Grant what you'll use; you can come back to this in Settings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                OnboardingPermission(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Move windows between displays and paste from clipboard history.",
                    granted: permissions.accessibility,
                    grant: permissions.requestAccessibility
                )
                OnboardingPermission(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    detail: "Lock the keyboard for cleaning and show keystrokes in recordings.",
                    granted: permissions.inputMonitoring,
                    grant: permissions.requestInputMonitoring
                )
                OnboardingPermission(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Take screenshots and record the screen.",
                    granted: permissions.screenRecording,
                    grant: permissions.requestScreenRecording
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("macOS applies Input Monitoring and Screen Recording after Mac Utility restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Restart Mac Utility", action: AppRelauncher.relaunch)
                    .controlSize(.small)
            }

            HStack {
                Spacer()
                Button(permissions.allGranted ? "Done" : "Skip for now", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.2), value: permissions.allGranted)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

private struct OnboardingPermission: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(granted ? .green : .accentColor)
                .frame(width: 36, height: 36)
                .background((granted ? Color.green : .accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Grant…", action: grant)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .animation(.spring(duration: 0.3), value: granted)
    }
}

/// Quits and reopens the app, which macOS needs before some permissions apply.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
