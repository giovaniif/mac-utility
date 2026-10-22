import AppKit
import os

/// Session-level event tap that swallows every keyboard event, including
/// media/brightness/volume keys. Mouse and trackpad events are not in the
/// mask, so they pass through untouched.
@MainActor
final class KeyboardBlocker {
    private let log = Logger(subsystem: "com.giovani.MacUtility", category: "keyboard-clean")
    private var tap: TapHandle?
    private var source: CFRunLoopSource?

    var isActive: Bool { tap != nil }

    /// Returns false if the tap could not be created (missing permission).
    func start() -> Bool {
        guard tap == nil else { return true }

        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        mask |= 1 << KeyboardBlocker.systemDefinedType

        let handle = TapHandle()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardBlockerCallback,
            userInfo: Unmanaged.passUnretained(handle).toOpaque()
        ) else {
            log.error("event tap creation failed")
            return false
        }
        handle.port = port

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.tap = handle
        self.source = source
        log.info("keyboard blocked")
        return true
    }

    func stop() {
        guard let tap, let port = tap.port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(port)
        tap.port = nil
        self.tap = nil
        self.source = nil
        log.info("keyboard unblocked")
    }

    /// `NSEvent.EventType.systemDefined`; CGEventType has no case for it.
    nonisolated static let systemDefinedType: UInt32 = 14

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: media, brightness and volume keys.
    nonisolated static let auxControlButtonsSubtype: Int16 = 8
}

/// Box the C callback reads through `userInfo`. The tap's run loop source is
/// on the main run loop, so the callback and `KeyboardBlocker` never race.
private final class TapHandle: @unchecked Sendable {
    var port: CFMachPort?
}

private func keyboardBlockerCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let userInfo {
            let handle = Unmanaged<TapHandle>.fromOpaque(userInfo).takeUnretainedValue()
            if let port = handle.port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    case .keyDown, .keyUp, .flagsChanged:
        return nil
    default:
        // System-defined events also carry mouse button state (subtype 7), so
        // only swallow the media/brightness/volume keys (subtype 8).
        if type.rawValue == KeyboardBlocker.systemDefinedType,
           NSEvent(cgEvent: event)?.subtype.rawValue == KeyboardBlocker.auxControlButtonsSubtype {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
