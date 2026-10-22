import AppKit
import SwiftUI

/// One mark on a screenshot. Points are in image points, top-left origin.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow, line, rectangle, ellipse, pen, highlighter, text, counter, pixelate
    }

    var id = UUID()
    var kind: Kind
    var color: Color
    var lineWidth: CGFloat
    /// Start and end for shapes, every sample for pen and highlighter.
    var points: [CGPoint]
    var text = ""
    var number = 0

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    var fontSize: CGFloat { 12 + lineWidth * 3 }
    var counterRadius: CGFloat { 10 + lineWidth * 2 }

    /// Area used for picking and moving it with the select tool.
    var bounds: CGRect {
        switch kind {
        case .text:
            let width = max(CGFloat(text.count) * fontSize * 0.6, fontSize)
            return CGRect(x: start.x, y: start.y, width: width, height: fontSize * 1.3)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        default:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    func hitTest(_ point: CGPoint) -> Bool {
        bounds.insetBy(dx: -max(lineWidth, 6), dy: -max(lineWidth, 6)).contains(point)
    }

    func moved(by delta: CGSize) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    /// Draws the mark. `pixelated` is the whole screenshot pixelated, drawn at
    /// the screenshot's size and clipped to cover the pixelate region.
    func draw(in context: inout GraphicsContext, pixelated: Image?, imageSize: CGSize) {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        switch kind {
        case .arrow:
            context.stroke(Self.arrowShaft(from: start, to: end, width: lineWidth), with: .color(color), style: style)
            context.fill(Self.arrowHead(from: start, to: end, width: lineWidth), with: .color(color))
        case .line:
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), style: style)
        case .rectangle:
            context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(color), style: style)
        case .ellipse:
            context.stroke(Path(ellipseIn: rect), with: .color(color), style: style)
        case .pen:
            context.stroke(Self.smoothPath(points), with: .color(color), style: style)
        case .highlighter:
            var layer = context
            layer.blendMode = .multiply
            layer.stroke(
                Self.smoothPath(points),
                with: .color(color.opacity(0.4)),
                style: StrokeStyle(lineWidth: lineWidth * 5, lineCap: .round, lineJoin: .round)
            )
        case .text:
            let label = Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            context.draw(label, at: start, anchor: .topLeading)
        case .counter:
            let r = counterRadius
            let circle = CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: circle), with: .color(color))
            let label = Text("\(number)")
                .font(.system(size: r * 1.1, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            context.draw(label, at: start, anchor: .center)
        case .pixelate:
            guard let pixelated else { return }
            context.drawLayer { layer in
                layer.clip(to: Path(rect))
                layer.draw(pixelated, in: CGRect(origin: .zero, size: imageSize))
            }
        }
    }

    private static func arrowGeometry(from start: CGPoint, to end: CGPoint, width: CGFloat) -> (angle: CGFloat, headLength: CGFloat) {
        (atan2(end.y - start.y, end.x - start.x), max(14, width * 4))
    }

    /// Stops short of the tip so the round cap doesn't poke through the head.
    static func arrowShaft(from start: CGPoint, to end: CGPoint, width: CGFloat) -> Path {
        let (angle, head) = arrowGeometry(from: start, to: end, width: width)
        let length = hypot(end.x - start.x, end.y - start.y)
        let shaft = max(length - head * 0.8, 0)
        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: start.x + cos(angle) * shaft, y: start.y + sin(angle) * shaft))
        return path
    }

    static func arrowHead(from start: CGPoint, to end: CGPoint, width: CGFloat) -> Path {
        let (angle, head) = arrowGeometry(from: start, to: end, width: width)
        let spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread)))
        path.addLine(to: CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread)))
        path.closeSubpath()
        return path
    }

    /// Quadratic curves through the midpoints, so freehand strokes look smooth.
    static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
