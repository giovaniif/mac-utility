import Foundation
import IOKit

/// Spots three- or four-finger swipes on any trackpad, and two-finger
/// horizontal swipes on a Magic Mouse, so Focus can stand in for Mission
/// Control and for switching Spaces.
///
/// macOS has no public API for global trackpad gestures. This reads raw
/// touches from the private MultitouchSupport framework, loaded at runtime,
/// the way MiddleClick, Jitouch and BetterTouchTool do. If the framework or a
/// symbol is missing, it quietly does nothing. Devices connected later (an
/// external Magic Trackpad or Magic Mouse) are picked up through IOKit.
final class TrackpadSwipe: @unchecked Sendable {
    enum Direction: Sendable { case up, down, left, right }

    static let shared = TrackpadSwipe()

    /// Per-device tracking, so two trackpads touched at once don't mix.
    private struct Track {
        var start: (x: Float, y: Float, time: Double)?
        var fired = false
    }

    private let lock = NSLock()
    private var fingers = 3
    private var tracks: [UnsafeMutableRawPointer: Track] = [:]
    private var mice: Set<UnsafeMutableRawPointer> = []
    private var list: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var handler: (@MainActor @Sendable (Direction) -> Void)?
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var rescanPending = false

    /// Normalized pad lengths (0–1) the fingers must travel within `window`
    /// seconds, mostly along one axis.
    private let distance: Float = 0.12
    private let window = 0.6

    /// MultitouchSupport family IDs for Magic Mouse and Magic Mouse 2.
    private static let mouseFamilies: Set<Int32> = [112, 113]

    @MainActor
    func start(fingers: Int, onSwipe: @escaping @MainActor @Sendable (Direction) -> Void) {
        stop()
        guard MultitouchAPI.load() != nil else { return }
        lock.withLock {
            self.fingers = fingers
            self.handler = onSwipe
        }
        attachDevices()
        watchForNewDevices()
    }

    @MainActor
    func stop() {
        unwatch()
        detachDevices()
        lock.withLock { handler = nil }
    }

    @MainActor
    private func attachDevices() {
        guard let api = MultitouchAPI.load(), let list = api.createList()?.takeRetainedValue() else { return }
        var found: [UnsafeMutableRawPointer] = []
        var mice: Set<UnsafeMutableRawPointer> = []
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var family: Int32 = 0
            if let familyID = api.familyID, familyID(device, &family) == 0, Self.mouseFamilies.contains(family) {
                mice.insert(device)
            }
            found.append(device)
        }
        lock.withLock {
            self.mice = mice
            self.tracks = [:]
        }
        // Keep the list alive: the device pointers belong to it.
        self.list = list
        devices = found
        for device in found {
            api.register(device, contactFrame)
            api.start(device, 0)
        }
    }

    @MainActor
    private func detachDevices() {
        if let api = MultitouchAPI.load() {
            for device in devices {
                api.unregister?(device, contactFrame)
                api.stop(device)
            }
        }
        devices.removeAll()
        list = nil
        lock.withLock {
            tracks = [:]
            mice = []
        }
    }

    /// Rebuilds the device list whenever a multitouch device shows up.
    @MainActor
    private func watchForNewDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
            { context, iterator in
                drain(iterator)
                guard let context else { return }
                let swipe = Unmanaged<TrackpadSwipe>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { swipe.scheduleRescan() }
            },
            context, &addedIterator
        )
        // Arms the notification; the devices already present are attached.
        if result == KERN_SUCCESS { drain(addedIterator) }
    }

    @MainActor
    private func unwatch() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    /// A Bluetooth device registers before MultitouchSupport can drive it.
    @MainActor
    private func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            MainActor.assumeIsolated {
                rescanPending = false
                guard lock.withLock({ handler != nil }) else { return }
                detachDevices()
                attachDevices()
            }
        }
    }

    /// Called on MultitouchSupport's own thread for every touch frame.
    fileprivate func frame(_ device: UnsafeMutableRawPointer?, _ touches: UnsafeMutableRawPointer?, count: Int, time: Double) {
        guard let device else { return }
        lock.lock()
        defer { lock.unlock() }
        var track = tracks[device] ?? Track()
        defer { tracks[device] = track }
        guard count > 0, let touches else {
            // All fingers lifted: the next swipe can fire.
            track = Track()
            return
        }
        let isMouse = mice.contains(device)
        guard count == (isMouse ? 2 : fingers), !track.fired else {
            track.start = nil
            return
        }
        var x: Float = 0
        var y: Float = 0
        for index in 0..<count {
            let finger = touches.advanced(by: index * Finger.stride)
            x += finger.load(fromByteOffset: Finger.normalizedX, as: Float.self)
            y += finger.load(fromByteOffset: Finger.normalizedY, as: Float.self)
        }
        x /= Float(count)
        y /= Float(count)
        guard let origin = track.start, time - origin.time < window else {
            track.start = (x, y, time)
            return
        }
        let dy = y - origin.y
        let dx = x - origin.x
        let direction: Direction
        if !isMouse, abs(dy) > distance, abs(dy) > abs(dx) * 2 {
            direction = dy > 0 ? .up : .down
        } else if abs(dx) > distance, abs(dx) > abs(dy) * 2 {
            direction = dx > 0 ? .right : .left
        } else {
            return
        }
        guard let handler else { return }
        track.fired = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(direction) }
        }
    }
}

private func drain(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
}

/// Memory layout of MultitouchSupport's per-finger record (96 bytes), as
/// documented by the open-source projects that use it.
private enum Finger {
    static let stride = 96
    static let normalizedX = 32
    static let normalizedY = 36
}

private func contactFrame(_ device: UnsafeMutableRawPointer?, _ touches: UnsafeMutableRawPointer?, _ count: Int32, _ time: Double, _ frame: Int32) -> Int32 {
    TrackpadSwipe.shared.frame(device, touches, count: Int(count), time: time)
    return 0
}

private struct MultitouchAPI {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void

    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: Register
    let unregister: Register?
    let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    let stop: @convention(c) (UnsafeMutableRawPointer) -> Void
    let familyID: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32)?

    nonisolated(unsafe) private static var cached: MultitouchAPI??

    static func load() -> MultitouchAPI? {
        if let cached { return cached }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY),
              let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop") else {
            cached = .some(nil)
            return nil
        }
        let api = MultitouchAPI(
            createList: unsafeBitCast(createList, to: (@convention(c) () -> Unmanaged<CFArray>?).self),
            register: unsafeBitCast(register, to: Register.self),
            unregister: dlsym(handle, "MTUnregisterContactFrameCallback").map { unsafeBitCast($0, to: Register.self) },
            start: unsafeBitCast(start, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self),
            stop: unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self),
            familyID: dlsym(handle, "MTDeviceGetFamilyID").map {
                unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32).self)
            }
        )
        cached = .some(api)
        return api
    }
}
