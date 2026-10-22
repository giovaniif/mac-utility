import SwiftUI

struct OnboardingView: View {
    let permissions: Permissions
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mac Utility lives in your menu bar.")
                .font(.title2.bold())
            Text("It needs a few permissions to work. Grant them in System Settings, then come back here.")
                .foregroundStyle(.secondary)
            Form {
                PermissionRows(permissions: permissions)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(permissions.allGranted ? "Done" : "Later", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}
