import Foundation

/// Spots a vertical swipe with three or four fingers on any trackpad, so the
/// switcher can stand in for Mission Control's gesture.
///
/// macOS has no public API for global trackpad gestures. This reads raw
/// touches from the private MultitouchSupport framework, loaded at runtime,
/// the way MiddleClick, Jitouch and BetterTouchTool do. If the framework or a
/// symbol is missing, it quietly does nothing.
final class TrackpadSwipe: @unchecked Sendable {
    enum Direction: Sendable { case up, down }

    static let shared = TrackpadSwipe()

    private let lock = NSLock()
    private var fingers = 3
    private var start: (x: Float, y: Float, time: Double)?
    private var fired = false
    private var devices: [UnsafeMutableRawPointer] = []
    private var handler: (@MainActor @Sendable (Direction) -> Void)?

    /// Normalized trackpad heights (0 bottom, 1 top) the fingers must travel,
    /// within `window` seconds, mostly vertically.
    private let distance: Float = 0.12
    private let window = 0.6

    @MainActor
    func start(fingers: Int, onSwipe: @escaping @MainActor @Sendable (Direction) -> Void) {
        stop()
        guard let api = MultitouchAPI.load(), let list = api.createList()?.takeRetainedValue() else { return }
        lock.withLock {
            self.fingers = fingers
            self.handler = onSwipe
            self.start = nil
            self.fired = false
        }
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            api.register(device, contactFrame)
            api.start(device, 0)
            devices.append(device)
        }
    }

    @MainActor
    func stop() {
        if let api = MultitouchAPI.load() {
            for device in devices { api.stop(device) }
        }
        devices.removeAll()
        lock.withLock { handler = nil }
    }

    /// Called on MultitouchSupport's own thread for every touch frame.
    fileprivate func frame(_ touches: UnsafeMutableRawPointer?, count: Int, time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0, let touches else {
            // All fingers lifted: the next swipe can fire.
            start = nil
            fired = false
            return
        }
        guard count == fingers, !fired else {
            start = nil
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
        guard let origin = start, time - origin.time < window else {
            start = (x, y, time)
            return
        }
        let dy = y - origin.y
        let dx = x - origin.x
        guard abs(dy) > distance, abs(dy) > abs(dx) * 2, let handler else { return }
        fired = true
        let direction: Direction = dy > 0 ? .up : .down
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(direction) }
        }
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
    TrackpadSwipe.shared.frame(touches, count: Int(count), time: time)
    return 0
}

private struct MultitouchAPI {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    let stop: @convention(c) (UnsafeMutableRawPointer) -> Void

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
            register: unsafeBitCast(register, to: (@convention(c) (UnsafeMutableRawPointer, Callback) -> Void).self),
            start: unsafeBitCast(start, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self),
            stop: unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        )
        cached = .some(api)
        return api
    }
}
