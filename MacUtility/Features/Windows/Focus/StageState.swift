import Foundation

/// CGWindowID of a managed window.
typealias WindowID = UInt32

enum SetLayout: String, Codable, Sendable {
    case split, stacked
}

/// How a split set divides the stage, named after vim's splits.
enum SplitAxis: String, Codable, Sendable {
    /// Side by side, like `:vsplit`.
    case vertical
    /// Top and bottom, like `:split`.
    case horizontal
}

enum PaneDirection: Sendable {
    case left, down, up, right
}

/// Up to two windows shown together on the stage.
struct FocusSet: Codable, Equatable, Sendable {
    var windows: [WindowID] = []
    var focused: WindowID?
    var layout: SetLayout = .split
    var ratio: Double = 0.5
    var axis: SplitAxis = .vertical

    init() {}

    // Sets saved before `axis` existed decode as side by side.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decode([WindowID].self, forKey: .windows)
        focused = try container.decodeIfPresent(WindowID.self, forKey: .focused)
        layout = try container.decodeIfPresent(SetLayout.self, forKey: .layout) ?? .split
        ratio = try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
        axis = try container.decodeIfPresent(SplitAxis.self, forKey: .axis) ?? .vertical
    }

    var isEmpty: Bool { windows.isEmpty }
    var hasRoom: Bool { windows.count < StageState.maxPerSet }

    /// The window that isn't focused, when there are two.
    var unfocused: WindowID? {
        windows.count == 2 ? windows.first { $0 != focused } : nil
    }

    /// Removes a window, moving focus to the one left. Returns its index.
    @discardableResult
    mutating func remove(_ id: WindowID) -> Int? {
        guard let index = windows.firstIndex(of: id) else { return nil }
        windows.remove(at: index)
        if focused == id { focused = windows.first }
        if windows.isEmpty { layout = .split }
        return index
    }

    mutating func insert(_ id: WindowID, at index: Int? = nil) {
        guard !windows.contains(id) else { return }
        windows.insert(id, at: min(index ?? windows.count, windows.count))
        if focused == nil { focused = id }
    }
}

/// The nine sets and which one is on the stage. Pure value type: every rule
/// from the Focus spec lives here so it can be tested without AppKit.
struct StageState: Codable, Equatable, Sendable {
    static let setCount = 9
    static let maxPerSet = 2
    static let numbers = 1...setCount

    var sets: [FocusSet] = Array(repeating: FocusSet(), count: setCount)
    var current = 1
    var previous: Int?

    subscript(set number: Int) -> FocusSet {
        get { sets[number - 1] }
        set { sets[number - 1] = newValue }
    }

    var currentSet: FocusSet {
        get { self[set: current] }
        set { self[set: current] = newValue }
    }

    var allWindows: [WindowID] { sets.flatMap(\.windows) }
    var occupied: [Int] { Self.numbers.filter { !self[set: $0].isEmpty } }

    func setNumber(of id: WindowID) -> Int? {
        Self.numbers.first { self[set: $0].windows.contains(id) }
    }

    func contains(_ id: WindowID) -> Bool { setNumber(of: id) != nil }

    func lowestEmpty(excluding excluded: Int? = nil) -> Int? {
        Self.numbers.first { $0 != excluded && self[set: $0].isEmpty }
    }

    func lowestWithRoom(excluding excluded: Int? = nil) -> Int? {
        Self.numbers.first { $0 != excluded && self[set: $0].hasRoom }
    }

    // MARK: Navigation

    mutating func goTo(_ number: Int) {
        guard Self.numbers.contains(number), number != current else { return }
        previous = current
        current = number
    }

    mutating func back() {
        if let previous { goTo(previous) }
    }

    // MARK: Adding and removing

    enum AddOutcome: Equatable {
        /// Joined the set on the stage.
        case joinedCurrent
        /// Went to another set; `switched` when the stage followed it.
        case placed(Int, switched: Bool, becauseFull: Bool)
        /// Every set is full: the window stays unmanaged.
        case unmanaged
    }

    /// The new-window rule. `preferred` is a pinned or remembered set;
    /// `activate` says the user is looking at this window, so the stage follows it.
    @discardableResult
    mutating func add(_ id: WindowID, preferred: Int? = nil, activate: Bool = true) -> AddOutcome {
        if let existing = setNumber(of: id) {
            return existing == current ? .joinedCurrent : .placed(existing, switched: false, becauseFull: false)
        }
        if let preferred, Self.numbers.contains(preferred), self[set: preferred].hasRoom {
            return place(id, in: preferred, activate: activate, becauseFull: false)
        }
        if currentSet.hasRoom {
            return place(id, in: current, activate: activate, becauseFull: false)
        }
        if let number = lowestEmpty() ?? lowestWithRoom() {
            return place(id, in: number, activate: activate, becauseFull: true)
        }
        return .unmanaged
    }

    private mutating func place(_ id: WindowID, in number: Int, activate: Bool, becauseFull: Bool) -> AddOutcome {
        self[set: number].insert(id)
        if activate { self[set: number].focused = id }
        if number == current { return .joinedCurrent }
        if activate { goTo(number) }
        return .placed(number, switched: activate, becauseFull: becauseFull)
    }

    /// Removes a window from its set. An emptied set keeps its number and the
    /// stage stays where it is. Returns the set it was in.
    @discardableResult
    mutating func remove(_ id: WindowID) -> Int? {
        guard let number = setNumber(of: id) else { return nil }
        self[set: number].remove(id)
        return number
    }

    /// Drops windows that no longer exist.
    mutating func prune(keeping live: Set<WindowID>) {
        for id in allWindows where !live.contains(id) { remove(id) }
    }

    /// First start: the frontmost window gets set 1 to itself; then each app
    /// gets the next empty set, up to two windows each, front to back.
    /// Returns the windows that didn't fit.
    @discardableResult
    mutating func adopt(_ windows: [(id: WindowID, app: String)]) -> [WindowID] {
        var appSet: [String: Int] = [:]
        var leftOver: [WindowID] = []
        for (index, window) in windows.enumerated() where !contains(window.id) {
            if index == 0, let number = lowestEmpty() {
                self[set: number].insert(window.id)
                current = number
                // The first window has its set to itself.
                continue
            }
            if let number = appSet[window.app], self[set: number].hasRoom, number != current {
                self[set: number].insert(window.id)
            } else if let number = lowestEmpty() {
                self[set: number].insert(window.id)
                appSet[window.app] = number
            } else {
                leftOver.append(window.id)
            }
        }
        return leftOver
    }

    // MARK: Within a set

    /// Focus moved to this window, by click, ⌘Tab or Dock. If it sits in
    /// another set, the stage follows. Returns true when the set changed.
    @discardableResult
    mutating func focus(_ id: WindowID) -> Bool {
        guard let number = setNumber(of: id) else { return false }
        self[set: number].focused = id
        guard number != current else { return false }
        goTo(number)
        return true
    }

    mutating func focusOther() {
        guard let other = currentSet.unfocused else { return }
        currentSet.focused = other
    }

    mutating func swapOrder() {
        guard currentSet.windows.count == 2 else { return }
        currentSet.windows.reverse()
    }

    mutating func toggleLayout() {
        guard currentSet.windows.count == 2 else { return }
        currentSet.layout = currentSet.layout == .split ? .stacked : .split
    }

    /// `v`/`s` on a full set: side by side or top and bottom, shown split.
    mutating func setAxis(_ axis: SplitAxis) {
        currentSet.axis = axis
        currentSet.layout = .split
    }

    /// Flip a split between side by side and top and bottom. A stacked set
    /// comes back split. Returns false when there's nothing to flip.
    @discardableResult
    mutating func toggleAxis() -> Bool {
        guard currentSet.windows.count == 2 else { return false }
        setAxis(currentSet.layout == .stacked ? currentSet.axis : (currentSet.axis == .vertical ? .horizontal : .vertical))
        return true
    }

    /// Focus the pane in a direction, like vim's Ctrl-w h/j/k/l. Returns
    /// false when there's no pane that way.
    @discardableResult
    mutating func focusPane(_ direction: PaneDirection) -> Bool {
        let set = currentSet
        guard set.windows.count == 2, set.layout == .split else { return false }
        let target: WindowID? = switch (set.axis, direction) {
        case (.vertical, .left), (.horizontal, .up): set.windows[0]
        case (.vertical, .right), (.horizontal, .down): set.windows[1]
        default: nil
        }
        guard let target, target != set.focused else { return false }
        currentSet.focused = target
        return true
    }

    /// Split: bring a window from another set into the current one, beside
    /// the focused window. Returns the set it came from.
    @discardableResult
    mutating func pullIn(_ id: WindowID, axis: SplitAxis) -> Int? {
        guard currentSet.hasRoom, let from = setNumber(of: id), from != current else { return nil }
        self[set: from].remove(id)
        currentSet.insert(id)
        currentSet.focused = id
        currentSet.axis = axis
        currentSet.layout = .split
        return from
    }

    /// Split with a window that isn't managed yet (an app opening a window).
    mutating func pullInNew(_ id: WindowID, axis: SplitAxis) -> Bool {
        guard currentSet.hasRoom, !contains(id) else { return false }
        currentSet.insert(id)
        currentSet.focused = id
        currentSet.axis = axis
        currentSet.layout = .split
        return true
    }

    /// Only, like vim's Ctrl-w o: keep the focused window, move the other to
    /// a new set. Returns where it went, or nil when nothing moved.
    @discardableResult
    mutating func only() -> Int? {
        guard let other = currentSet.unfocused,
              let target = lowestEmpty(excluding: current) ?? lowestWithRoom(excluding: current) else { return nil }
        currentSet.remove(other)
        self[set: target].insert(other)
        return target
    }

    mutating func setRatio(_ ratio: Double) {
        currentSet.ratio = Self.snap(ratio)
    }

    /// Magnetic stops at 1/3, 1/2 and 2/3; free in between, within limits.
    static func snap(_ ratio: Double) -> Double {
        for stop in [1.0 / 3, 0.5, 2.0 / 3] where abs(ratio - stop) < 0.035 {
            return stop
        }
        return min(max(ratio, 0.2), 0.8)
    }

    // MARK: Moving between sets

    /// Send a window to set `number`. Joins it when there's room, otherwise
    /// swaps with that set's unfocused window. The stage stays put.
    mutating func send(_ id: WindowID, to number: Int) {
        guard Self.numbers.contains(number), let from = setNumber(of: id), from != number else { return }
        if self[set: number].hasRoom {
            self[set: from].remove(id)
            self[set: number].insert(id)
            return
        }
        guard let out = self[set: number].unfocused ?? self[set: number].windows.last,
              let outIndex = self[set: number].windows.firstIndex(of: out) else { return }
        let fromIndex = self[set: from].remove(id)
        self[set: number].windows[outIndex] = id
        self[set: from].insert(out, at: fromIndex)
    }

    /// Replace: `focused` and `other` (in another set) trade places. Returns
    /// the set the replaced window went to.
    @discardableResult
    mutating func replace(_ focused: WindowID, with other: WindowID) -> Int? {
        guard let a = setNumber(of: focused), let b = setNumber(of: other), a != b,
              let ia = self[set: a].windows.firstIndex(of: focused),
              let ib = self[set: b].windows.firstIndex(of: other) else { return nil }
        self[set: a].windows[ia] = other
        self[set: b].windows[ib] = focused
        self[set: a].focused = other
        if self[set: b].focused == other { self[set: b].focused = focused }
        return b
    }

    /// Replace with a window that isn't managed yet (a new app): it takes the
    /// focused window's place, and that window moves to a new set. Returns
    /// where it went, or nil when no set had room and it became unmanaged.
    @discardableResult
    mutating func replace(_ focused: WindowID, withNew new: WindowID) -> Int? {
        guard let a = setNumber(of: focused), !contains(new),
              let index = self[set: a].windows.firstIndex(of: focused) else { return nil }
        self[set: a].windows[index] = new
        self[set: a].focused = new
        guard let target = lowestEmpty(excluding: a) ?? lowestWithRoom(excluding: a) else { return nil }
        self[set: target].insert(focused)
        return target
    }
}
