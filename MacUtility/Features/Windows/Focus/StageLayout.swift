import CoreGraphics

/// Frame math for the stage. All rects use Accessibility coordinates: origin
/// at the top-left of the primary display, y growing down.
struct StageLayout {
    /// The managed display's visible frame (no menu bar, no Dock).
    var stage: CGRect
    var gap: CGFloat = 12
    /// A lone window stops growing at this width and centers.
    var widthCap: CGFloat = 1440

    var inner: CGRect { stage.insetBy(dx: gap, dy: gap).integral }

    /// Frames for the windows that are visible; the rest get parked.
    func frames(for set: FocusSet, zoomed: WindowID? = nil) -> [WindowID: CGRect] {
        if let zoomed, set.windows.contains(zoomed) {
            return [zoomed: inner]
        }
        switch set.windows.count {
        case 0:
            return [:]
        case 1:
            return [set.windows[0]: single]
        default:
            if set.layout == .stacked {
                return [set.focused ?? set.windows[0]: single]
            }
            let (first, second) = split(ratio: set.ratio, axis: set.axis)
            return [set.windows[0]: first, set.windows[1]: second]
        }
    }

    var single: CGRect {
        let width = min(inner.width, widthCap)
        return CGRect(x: (inner.midX - width / 2).rounded(), y: inner.minY, width: width.rounded(), height: inner.height)
    }

    /// First and second pane: left and right, or top and bottom.
    func split(ratio: Double, axis: SplitAxis = .vertical) -> (CGRect, CGRect) {
        switch axis {
        case .vertical:
            let usable = inner.width - gap
            let leftWidth = (usable * CGFloat(ratio)).rounded()
            let left = CGRect(x: inner.minX, y: inner.minY, width: leftWidth, height: inner.height)
            let right = CGRect(x: left.maxX + gap, y: inner.minY, width: inner.maxX - left.maxX - gap, height: inner.height)
            return (left, right)
        case .horizontal:
            let usable = inner.height - gap
            let topHeight = (usable * CGFloat(ratio)).rounded()
            let top = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: topHeight)
            let bottom = CGRect(x: inner.minX, y: top.maxY + gap, width: inner.width, height: inner.maxY - top.maxY - gap)
            return (top, bottom)
        }
    }

    /// The split ratio implied by the user resizing one pane to `size`.
    func ratio(for size: CGSize, isFirst: Bool, axis: SplitAxis = .vertical) -> Double {
        let usable = (axis == .vertical ? inner.width : inner.height) - gap
        guard usable > 0 else { return 0.5 }
        let share = Double((axis == .vertical ? size.width : size.height) / usable)
        return isFirst ? share : 1 - share
    }

    /// Where a parked window goes: a corner of the managed display with a
    /// 1 pt sliver left on screen (macOS won't let a window leave entirely).
    /// Picks the corner whose off-screen side overlaps other displays least.
    static func parkingOrigin(size: CGSize, display: CGRect, otherDisplays: [CGRect]) -> CGPoint {
        let candidates = [
            CGPoint(x: display.maxX - 1, y: display.maxY - 1),
            CGPoint(x: display.minX - size.width + 1, y: display.maxY - 1),
        ]
        func overlap(_ origin: CGPoint) -> CGFloat {
            let rect = CGRect(origin: origin, size: size)
            return otherDisplays.reduce(0) { total, other in
                let hit = rect.intersection(other)
                return hit.isNull ? total : total + hit.width * hit.height
            }
        }
        return candidates.min { overlap($0) < overlap($1) } ?? candidates[0]
    }
}
