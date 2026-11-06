import CoreGraphics
import Foundation
import Testing

struct StageStateTests {
    @Test func newWindowJoinsCurrentSetWhileThereIsRoom() {
        var state = StageState()
        let result1 = state.add(1)
        #expect(result1 == .joinedCurrent)
        let result2 = state.add(2)
        #expect(result2 == .joinedCurrent)
        #expect(state[set: 1].windows == [1, 2])
        #expect(state[set: 1].focused == 2)
    }

    @Test func newWindowOpensLowestEmptySetWhenFull() {
        var state = StageState()
        state.add(1)
        state.add(2)
        state[set: 2].insert(9)
        let result1 = state.add(3)
        #expect(result1 == .placed(3, switched: true, becauseFull: true))
        #expect(state.current == 3)
        #expect(state.previous == 1)
    }

    @Test func backgroundWindowDoesNotMoveTheStage() {
        var state = StageState()
        state.add(1)
        state.add(2)
        let result1 = state.add(3, activate: false)
        #expect(result1 == .placed(2, switched: false, becauseFull: true))
        #expect(state.current == 1)
    }

    @Test func preferredSetWinsWhenItHasRoom() {
        var state = StageState()
        state.add(1)
        let result1 = state.add(2, preferred: 9)
        #expect(result1 == .placed(9, switched: true, becauseFull: false))
        #expect(state.current == 9)
    }

    @Test func fullPreferredSetFallsBackToTheRule() {
        var state = StageState()
        state[set: 9].insert(5)
        state[set: 9].insert(6)
        let result1 = state.add(1, preferred: 9)
        #expect(result1 == .joinedCurrent)
    }

    @Test func everySetFullLeavesWindowUnmanaged() {
        var state = StageState()
        for id in 1...18 { state.add(WindowID(id), activate: false) }
        let result1 = state.add(99)
        #expect(result1 == .unmanaged)
    }

    @Test func closingLastWindowKeepsTheEmptySet() {
        var state = StageState()
        state.add(1)
        state.goTo(2)
        state.add(2)
        state.remove(2)
        #expect(state.current == 2)
        #expect(state[set: 2].isEmpty)
    }

    @Test func closingFocusedWindowFocusesTheOther() {
        var state = StageState()
        state.add(1)
        state.add(2)
        state.remove(2)
        #expect(state[set: 1].focused == 1)
    }

    @Test func backAndForth() {
        var state = StageState()
        state.goTo(3)
        state.back()
        #expect(state.current == 1)
        state.back()
        #expect(state.current == 3)
    }

    @Test func focusingWindowInAnotherSetMovesTheStage() {
        var state = StageState()
        state.add(1)
        state[set: 4].insert(7)
        let result1 = state.focus(7)
        #expect(result1)
        #expect(state.current == 4)
        let result2 = state.focus(7)
        #expect(!result2)
    }

    @Test func sendJoinsSetWithRoom() {
        var state = StageState()
        state.add(1)
        state.add(2)
        state.send(2, to: 5)
        #expect(state[set: 1].windows == [1])
        #expect(state[set: 1].focused == 1)
        #expect(state[set: 5].windows == [2])
        #expect(state.current == 1)
    }

    @Test func sendToFullSetSwapsWithItsUnfocusedWindow() {
        var state = StageState()
        state.add(1)
        state.add(2) // focused, index 1
        state[set: 3].insert(30)
        state[set: 3].insert(31)
        state[set: 3].focused = 30
        state.send(2, to: 3)
        #expect(state[set: 3].windows == [30, 2])
        #expect(state[set: 1].windows == [1, 31])
    }

    @Test func replaceTradesPlaces() {
        var state = StageState()
        state.add(1)
        state.add(2)
        state[set: 3].insert(30)
        state[set: 3].insert(31)
        let result1 = state.replace(2, with: 31)
        #expect(result1 == 3)
        #expect(state[set: 1].windows == [1, 31])
        #expect(state[set: 1].focused == 31)
        #expect(state[set: 3].windows == [30, 2])
    }

    @Test func replaceWithNewAppPushesFocusedToNewSet() {
        var state = StageState()
        state.add(1)
        state.add(2)
        state[set: 2].insert(20)
        let result1 = state.replace(2, withNew: 50)
        #expect(result1 == 3)
        #expect(state[set: 1].windows == [1, 50])
        #expect(state[set: 1].focused == 50)
        #expect(state[set: 3].windows == [2])
    }

    @Test func undoIsRestoringASnapshot() {
        var state = StageState()
        state.add(1)
        state[set: 2].insert(20)
        let before = state
        state.replace(1, with: 20)
        state = before
        #expect(state[set: 1].windows == [1])
    }

    @Test func adoptGivesFrontWindowItsOwnSetAndGroupsByApp() {
        var state = StageState()
        let left = state.adopt([
            (1, "editor"), (2, "browser"), (3, "browser"), (4, "browser"), (5, "editor"),
        ])
        #expect(state.current == 1)
        #expect(state[set: 1].windows == [1])
        #expect(state[set: 2].windows == [2, 3])
        #expect(state[set: 3].windows == [4])
        #expect(state[set: 4].windows == [5])
        #expect(left.isEmpty)
    }

    @Test func pruneDropsDeadWindows() {
        var state = StageState()
        state.add(1)
        state.add(2)
        state.prune(keeping: [2])
        #expect(state.allWindows == [2])
    }

    @Test func toggleLayoutNeedsTwoWindows() {
        var state = StageState()
        state.add(1)
        state.toggleLayout()
        #expect(state.currentSet.layout == .split)
        state.add(2)
        state.toggleLayout()
        #expect(state.currentSet.layout == .stacked)
    }

    @Test func ratioSnaps() {
        #expect(StageState.snap(0.51) == 0.5)
        #expect(StageState.snap(0.65) == 2.0 / 3)
        #expect(StageState.snap(0.42) == 0.42)
        #expect(StageState.snap(0.05) == 0.2)
    }

    @Test func roundTripsThroughJSON() throws {
        var state = StageState()
        state.add(1)
        state.add(2)
        state.toggleLayout()
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(StageState.self, from: data) == state)
    }
}

struct StageLayoutTests {
    // MacBook Air 13" visible frame below a 24 pt menu bar.
    let laptop = StageLayout(stage: CGRect(x: 0, y: 24, width: 1440, height: 876))
    // 1920×1080 desktop.
    let desktop = StageLayout(stage: CGRect(x: 0, y: 25, width: 1920, height: 1055))

    @Test func singleWindowFillsLaptopStage() {
        var set = FocusSet()
        set.insert(1)
        #expect(laptop.frames(for: set)[1] == CGRect(x: 12, y: 36, width: 1416, height: 852))
    }

    @Test func singleWindowIsCappedAndCenteredOnDesktop() {
        var set = FocusSet()
        set.insert(1)
        #expect(desktop.frames(for: set)[1] == CGRect(x: 240, y: 37, width: 1440, height: 1031))
    }

    @Test func splitUsesFullWidthWithGap() {
        var set = FocusSet()
        set.insert(1)
        set.insert(2)
        let frames = desktop.frames(for: set)
        let left = try! #require(frames[1])
        let right = try! #require(frames[2])
        #expect(left.minX == 12)
        #expect(right.minX - left.maxX == 12)
        #expect(right.maxX == 1908)
        #expect(abs(left.width - right.width) <= 1)
    }

    @Test func stackedShowsOnlyFocused() {
        var set = FocusSet()
        set.insert(1)
        set.insert(2)
        set.layout = .stacked
        set.focused = 2
        #expect(Array(laptop.frames(for: set).keys) == [2])
    }

    @Test func zoomFillsInnerStageWithoutCap() {
        var set = FocusSet()
        set.insert(1)
        set.insert(2)
        #expect(desktop.frames(for: set, zoomed: 2) == [2: desktop.inner])
    }

    @Test func ratioFromResize() {
        let (left, _) = laptop.split(ratio: 0.5)
        #expect(abs(laptop.ratio(forWidth: left.width, isLeft: true) - 0.5) < 0.01)
        #expect(abs(laptop.ratio(forWidth: left.width, isLeft: false) - 0.5) < 0.01)
    }

    @Test func parkingAvoidsOtherDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rightOfMain = CGRect(x: 1920, y: 600, width: 1512, height: 982)
        let origin = StageLayout.parkingOrigin(size: CGSize(width: 800, height: 600), display: main, otherDisplays: [rightOfMain])
        #expect(origin == CGPoint(x: -799, y: 1079))
        let alone = StageLayout.parkingOrigin(size: CGSize(width: 800, height: 600), display: main, otherDisplays: [])
        #expect(alone == CGPoint(x: 1919, y: 1079))
    }
}
