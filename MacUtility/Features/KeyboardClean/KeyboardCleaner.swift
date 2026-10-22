import Foundation
import Observation
import os

/// Ties the blocker, overlay and auto-unlock timer together.
@MainActor
@Observable
final class KeyboardCleaner {
    private(set) var isLocked = false

    @ObservationIgnored private let log = Logger(subsystem: "com.giovani.MacUtility", category: "keyboard-clean")
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let blocker = KeyboardBlocker()
    @ObservationIgnored private let overlay = CleaningOverlay()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var deadline = Date()

    /// Seconds before auto-unlock. Override with
    /// `defaults write com.giovani.MacUtility keyboardCleaningTimeout <n>`.
    private var timeout: Int {
        let value = UserDefaults.standard.integer(forKey: "keyboardCleaningTimeout")
        return value > 0 ? value : 60
    }

    init(permissions: Permissions) {
        self.permissions = permissions
    }

    func toggle() {
        isLocked ? unlock() : lock()
    }

    private func lock() {
        permissions.refresh()
        guard permissions.inputMonitoring else { return permissions.requestInputMonitoring() }
        guard permissions.accessibility else { return permissions.requestAccessibility() }
        guard blocker.start() else { return }

        let seconds = timeout
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        overlay.show(seconds: seconds) { [weak self] in self?.unlock() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        isLocked = true
        log.info("locked for \(seconds)s")
    }

    private func tick() {
        let remaining = Int(deadline.timeIntervalSinceNow.rounded(.up))
        if remaining <= 0 {
            unlock()
        } else {
            overlay.update(remaining: remaining)
        }
    }

    private func unlock() {
        timer?.invalidate()
        timer = nil
        blocker.stop()
        overlay.hide()
        isLocked = false
        log.info("unlocked")
    }
}
