import AppKit

/// Pure geometry for moving a window between displays. All rects are in
/// Cocoa coordinates (bottom-left origin of the primary screen).
enum ScreenGeometry {
    /// AX uses a top-left origin anchored to the primary screen; Cocoa uses
    /// bottom-left. The conversion is its own inverse.
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Screens ordered left to right, top to bottom for equal x.
    static func ordered(_ frames: [CGRect]) -> [Int] {
        frames.indices.sorted {
            frames[$0].minX != frames[$1].minX ? frames[$0].minX < frames[$1].minX : frames[$0].maxY > frames[$1].maxY
        }
    }

    /// Index of the screen holding the largest part of the window.
    static func screenIndex(for window: CGRect, in frames: [CGRect]) -> Int? {
        let areas = frames.map { frame -> CGFloat in
            let overlap = frame.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else {
            return nil
        }
        return best
    }

    /// Centers the window in the target visible frame, shrinking it if it
    /// doesn't fit.
    static func center(_ window: CGRect, in target: CGRect) -> CGRect {
        let width = min(window.width, target.width)
        let height = min(window.height, target.height)
        return CGRect(x: target.midX - width / 2, y: target.midY - height / 2, width: width, height: height).integral
    }
}
