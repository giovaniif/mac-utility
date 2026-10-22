import AppKit
import ApplicationServices
import Observation

/// Tracks Accessibility and Input Monitoring grants. macOS posts no change
/// notification for either, so state is polled while someone is watching.
@MainActor
@Observable
final class Permissions {
    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var inputMonitoring = CGPreflightListenEventAccess()
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()

    var allGranted: Bool { accessibility && inputMonitoring }

    private var timer: Timer?

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("Privacy_Accessibility")
        }
    }

    func requestInputMonitoring() {
        if !CGRequestListenEventAccess() {
            open("Privacy_ListenEvent")
        }
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("Privacy_ScreenCapture")
        }
    }

    private func open(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
