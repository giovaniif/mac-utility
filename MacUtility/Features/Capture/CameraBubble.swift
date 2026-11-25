import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Looks for the camera bubble. Pick one in the camera menu on the recording
/// bar, or double-click the bubble for the next one.
enum CameraStyle: String, CaseIterable, Identifiable {
    case circle, squircle, widescreen, portrait, aura, neon, polaroid, pop, hexagon, blob

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: "Circle"
        case .squircle: "Rounded"
        case .widescreen: "Widescreen"
        case .portrait: "Portrait"
        case .aura: "Aura"
        case .neon: "Neon"
        case .polaroid: "Polaroid"
        case .pop: "Pop Art"
        case .hexagon: "Hexagon"
        case .blob: "Lava Lamp"
        }
    }

    var symbol: String {
        switch self {
        case .circle: "circle"
        case .squircle: "app"
        case .widescreen: "rectangle"
        case .portrait: "rectangle.portrait"
        case .aura: "sparkles"
        case .neon: "bolt"
        case .polaroid: "photo"
        case .pop: "paintpalette"
        case .hexagon: "hexagon"
        case .blob: "drop"
        }
    }

    /// Styles that move redraw every frame; the rest only on change.
    var animated: Bool { self == .aura || self == .neon || self == .blob }

    /// Size of the camera picture for a bubble `base` points across.
    func feedSize(_ base: CGFloat) -> CGSize {
        switch self {
        case .widescreen: CGSize(width: base * 1.5, height: base * 0.85)
        case .portrait: CGSize(width: base * 0.8, height: base * 1.1)
        // A regular hexagon, point up.
        case .hexagon: CGSize(width: base * 0.92, height: base * 1.06)
        default: CGSize(width: base, height: base)
        }
    }

    static let auraRing: CGFloat = 9
    static let popOffset: CGFloat = 10
    static func polaroidPad(_ base: CGFloat) -> CGFloat { (base * 0.06).rounded() }
    static func polaroidCaption(_ base: CGFloat) -> CGFloat { (base * 0.24).rounded() }

    /// The picture plus its frame: what you see of the bubble.
    func contentSize(_ base: CGFloat) -> CGSize {
        let feed = feedSize(base)
        switch self {
        case .aura:
            return CGSize(width: feed.width + Self.auraRing * 2, height: feed.height + Self.auraRing * 2)
        case .polaroid:
            let pad = Self.polaroidPad(base)
            return CGSize(width: feed.width + pad * 2, height: feed.height + pad + Self.polaroidCaption(base))
        case .pop:
            return CGSize(width: feed.width + Self.popOffset, height: feed.height + Self.popOffset)
        default:
            return feed
        }
    }

    /// Outline the picture is cut to.
    func outline(base: CGFloat, time: Double) -> AnyShape {
        switch self {
        case .circle, .aura: AnyShape(Circle())
        case .squircle: AnyShape(RoundedRectangle(cornerRadius: base * 0.25, style: .continuous))
        case .widescreen, .portrait: AnyShape(RoundedRectangle(cornerRadius: base * 0.1, style: .continuous))
        case .neon: AnyShape(RoundedRectangle(cornerRadius: base * 0.16, style: .continuous))
        case .polaroid: AnyShape(Rectangle())
        case .pop: AnyShape(RoundedRectangle(cornerRadius: base * 0.12, style: .continuous))
        case .hexagon: AnyShape(Hexagon(cornerRadius: base * 0.07))
        case .blob: AnyShape(Blob(time: time))
        }
    }
}

/// Regular hexagon, point up, with rounded corners.
struct Hexagon: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / sqrt(3), rect.height / 2)
        let points = (0..<6).map { index -> CGPoint in
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            return CGPoint(x: rect.midX + radius * cos(angle), y: rect.midY + radius * sin(angle))
        }
        var path = Path()
        // Start halfway along a side so every corner gets rounded.
        path.move(to: CGPoint(x: (points[5].x + points[0].x) / 2, y: (points[5].y + points[0].y) / 2))
        for index in 0..<6 {
            path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % 6], radius: cornerRadius)
        }
        path.closeSubpath()
        return path
    }
}

/// Slowly wobbling, lava-lamp outline. Built from cosines only, so it's
/// mirror-symmetric top to bottom and reads the same in flipped and unflipped
/// coordinates (the picture's mask and the SwiftUI rim always line up).
struct Blob: Shape {
    var time: Double

    func path(in rect: CGRect) -> Path {
        let a = 0.07 * sin(time * 1.1)
        let b = 0.05 * sin(time * 0.7 + 1.3)
        let c = 0.035 * sin(time * 1.6 + 2.1)
        let radius = Double(min(rect.width, rect.height)) / 2 / (1 + 0.07 + 0.05 + 0.035)
        let steps = 120
        var path = Path()
        for step in 0..<steps {
            let theta = Double(step) / Double(steps) * 2 * .pi
            let wobble: Double = a * cos(2 * theta) + b * cos(3 * theta) + c * cos(5 * theta)
            let r: Double = radius * (1 + wobble)
            let point = CGPoint(x: rect.midX + CGFloat(r * cos(theta)), y: rect.midY + CGFloat(r * sin(theta)))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The live camera picture, cut to the style's outline.
final class CameraFeedView: NSView {
    private let preview = AVCaptureVideoPreviewLayer()
    private let mask = CAShapeLayer()

    var outline: AnyShape? {
        didSet { layoutFeed() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        preview.mask = mask
        layer?.addSublayer(preview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // The bubble's container takes the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ session: AVCaptureSession) {
        guard preview.session !== session else { return }
        preview.session = session
        mirror()
    }

    /// Mirror like a selfie camera.
    private func mirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported,
              !connection.isVideoMirrored
        else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    override func layout() {
        super.layout()
        layoutFeed()
        mirror()
    }

    private func layoutFeed() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        mask.frame = preview.bounds
        mask.path = outline?.path(in: bounds).cgPath
        CATransaction.commit()
    }
}

private struct CameraFeed: NSViewRepresentable {
    let session: AVCaptureSession
    let outline: AnyShape

    func makeNSView(context: Context) -> CameraFeedView { CameraFeedView(frame: .zero) }

    func updateNSView(_ view: CameraFeedView, context: Context) {
        view.show(session)
        view.outline = outline
    }
}

@MainActor
@Observable
final class CameraBubbleModel {
    var session: AVCaptureSession
    var style: CameraStyle
    var base: CGFloat

    init(session: AVCaptureSession, style: CameraStyle, base: CGFloat) {
        self.session = session
        self.style = style
        self.base = base
    }
}

private struct CameraBubbleView: View {
    let model: CameraBubbleModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.style.animated)) { context in
            bubble(time: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func bubble(time: Double) -> some View {
        let style = model.style
        let base = model.base
        let size = style.feedSize(base)
        let outline = style.outline(base: base, time: time)
        let feed = CameraFeed(session: model.session, outline: outline)
            .frame(width: size.width, height: size.height)
        let spin = { (speed: Double) in Angle.degrees((time * speed).truncatingRemainder(dividingBy: 360)) }

        switch style {
        case .circle, .squircle, .widescreen, .portrait, .hexagon:
            feed
                .background(outline.fill(.black).shadow(color: .black.opacity(0.35), radius: 12, y: 5))
                .overlay(outline.stroke(.white.opacity(0.9), lineWidth: style == .circle ? 3 : 2.5))

        case .aura:
            // Story-ring: a turning gradient, a white gap, then you.
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Self.auraColors, center: .center, angle: spin(70)))
                    .frame(width: size.width + CameraStyle.auraRing * 2, height: size.height + CameraStyle.auraRing * 2)
                    .shadow(color: Color(red: 0.95, green: 0.2, blue: 0.5).opacity(0.45), radius: 16)
                Circle()
                    .fill(.white)
                    .frame(width: size.width + 7, height: size.height + 7)
                feed
            }

        case .neon:
            let tube = AngularGradient(colors: Self.neonColors, center: .center, angle: spin(40))
            let flicker = 0.7 + 0.3 * sin(time * 2.4)
            feed
                .background(outline.fill(.black))
                .background(outline.stroke(tube, lineWidth: 10).blur(radius: 14).opacity(flicker))
                .overlay(outline.stroke(tube, lineWidth: 3.5))
                .overlay(outline.stroke(.white.opacity(0.55), lineWidth: 1))

        case .polaroid:
            let pad = CameraStyle.polaroidPad(base)
            VStack(spacing: 0) {
                feed.overlay(Rectangle().stroke(.black.opacity(0.12), lineWidth: 1))
                Text(Date.now.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.custom("Marker Felt", size: max(11, base * 0.085)))
                    .foregroundStyle(Color(white: 0.22))
                    .lineLimit(1)
                    .frame(width: size.width, height: CameraStyle.polaroidCaption(base))
            }
            .padding([.top, .horizontal], pad)
            .background(
                Rectangle()
                    .fill(Color(white: 0.97))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            )

        case .pop:
            // Neo-brutalist: a hard offset shadow in halftone yellow.
            let offset = CameraStyle.popOffset
            ZStack(alignment: .topLeading) {
                ZStack {
                    outline.fill(Color(red: 1, green: 0.83, blue: 0.15))
                    Halftone().clipShape(outline)
                    outline.stroke(.black, lineWidth: 4)
                }
                .frame(width: size.width, height: size.height)
                .offset(x: offset, y: offset)
                feed.overlay(outline.stroke(.black, lineWidth: 4))
            }
            .frame(width: size.width + offset, height: size.height + offset, alignment: .topLeading)

        case .blob:
            ZStack {
                outline
                    .fill(AngularGradient(colors: Self.lavaColors, center: .center, angle: spin(40)))
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(1.1)
                    .blur(radius: 14)
                    .opacity(0.9)
                feed.overlay(outline.stroke(.white.opacity(0.85), lineWidth: 2.5))
            }
        }
    }

    private static let auraColors: [Color] = [
        Color(red: 1, green: 0.82, blue: 0.25), Color(red: 1, green: 0.5, blue: 0.15),
        Color(red: 0.95, green: 0.2, blue: 0.5), Color(red: 0.6, green: 0.2, blue: 0.85),
        Color(red: 1, green: 0.82, blue: 0.25),
    ]
    private static let neonColors: [Color] = [
        Color(red: 0.2, green: 0.95, blue: 1), Color(red: 1, green: 0.2, blue: 0.85),
        Color(red: 0.55, green: 0.35, blue: 1), Color(red: 0.2, green: 0.95, blue: 1),
    ]
    private static let lavaColors: [Color] = [
        Color(red: 1, green: 0.35, blue: 0.55), Color(red: 0.65, green: 0.3, blue: 1),
        Color(red: 0.25, green: 0.55, blue: 1), Color(red: 0.3, green: 0.95, blue: 0.75),
        Color(red: 1, green: 0.35, blue: 0.55),
    ]
}

/// Comic-print dots.
private struct Halftone: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 7
            var row = 0
            for y in stride(from: 0, to: size.height + step, by: step) {
                let shift = row.isMultiple(of: 2) ? 0 : step / 2
                for x in stride(from: shift, to: size.width + step, by: step) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(Color(red: 0.9, green: 0.2, blue: 0.2).opacity(0.55)))
                }
                row += 1
            }
        }
    }
}

/// Takes every mouse event on the bubble: drag to move it, double-click for
/// the next style, scroll or pinch to resize.
private final class BubbleContainer: NSView {
    var onMoved: (@MainActor () -> Void)?
    var onDoubleClick: (@MainActor () -> Void)?
    var onResize: (@MainActor (CGFloat) -> Void)?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var moved = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            onDoubleClick?()
            return
        }
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(
            x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
            y: dragStart.origin.y + mouse.y - dragStart.mouse.y
        ))
        moved = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil, moved { onMoved?() }
        dragStart = nil
        moved = false
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 8 }
        if event.isDirectionInvertedFromDevice { delta = -delta }
        guard delta != 0 else { return }
        onResize?(1 + delta / 200)
    }

    override func magnify(with event: NSEvent) {
        onResize?(1 + event.magnification)
    }
}

/// Draggable camera bubble in one of several styles. It's a normal on-screen
/// window, so the recording picks it up like anything else.
@MainActor
final class CameraBubble {
    /// Room around the bubble for its shadow and glow.
    private static let margin: CGFloat = 32
    static let sizes: ClosedRange<CGFloat> = 110...420

    private let model: CameraBubbleModel
    private let panel: NSPanel
    private let queue = DispatchQueue(label: "com.giovani.MacUtility.camera")
    private var area = CGRect.zero
    /// Called when a double-click on the bubble changes its style.
    var onStyleChange: (@MainActor (CameraStyle) -> Void)?
    /// Called when scrolling or pinching on the bubble resizes it.
    var onSizeChange: (@MainActor (CGFloat) -> Void)?

    init?(device: AVCaptureDevice) {
        guard let session = Self.session(for: device) else { return nil }
        model = CameraBubbleModel(session: session, style: RecordingOptions.cameraStyle, base: RecordingOptions.cameraSize)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = BubbleContainer(frame: panel.contentLayoutRect)
        let hosting = NSHostingView(rootView: CameraBubbleView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        container.onMoved = { [weak self] in self?.rememberPosition() }
        container.onDoubleClick = { [weak self] in self?.nextStyle() }
        container.onResize = { [weak self] factor in
            guard let self else { return }
            setSize(model.base * factor)
            onSizeChange?(model.base)
        }
    }

    private static func session(for device: AVCaptureDevice) -> AVCaptureSession? {
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        return session
    }

    /// Shows the bubble where it was last left in the recorded area, or in
    /// its bottom-right corner the first time.
    func show(in area: CGRect) {
        self.area = area
        let visual = model.style.contentSize(model.base)
        let center: CGPoint = if let saved = RecordingOptions.cameraPosition {
            CGPoint(x: area.minX + saved.x * area.width, y: area.minY + saved.y * area.height)
        } else {
            CGPoint(x: area.maxX - 24 - visual.width / 2, y: area.minY + 24 + visual.height / 2)
        }
        place(center: center)
        panel.fadeIn(duration: 0.2)
        start(model.session)
    }

    func hide() {
        panel.orderOut(nil)
        stop(model.session)
    }

    func setStyle(_ style: CameraStyle) {
        guard style != model.style else { return }
        let center = self.center
        model.style = style
        RecordingOptions.cameraStyle = style
        place(center: center)
    }

    func setSize(_ base: CGFloat) {
        let base = min(max(base, Self.sizes.lowerBound), Self.sizes.upperBound)
        guard base != model.base else { return }
        let center = self.center
        model.base = base
        RecordingOptions.cameraSize = base
        place(center: center)
    }

    /// Switches cameras without moving the bubble.
    func setDevice(_ device: AVCaptureDevice) {
        guard let session = Self.session(for: device) else { return }
        let old = model.session
        model.session = session
        start(session)
        stop(old)
    }

    private func nextStyle() {
        let all = CameraStyle.allCases
        let index = all.firstIndex(of: model.style) ?? 0
        let next = all[(index + 1) % all.count]
        setStyle(next)
        onStyleChange?(next)
    }

    private var center: CGPoint { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }

    /// Centers the bubble on `center`, kept inside the recorded area when it fits.
    private func place(center: CGPoint) {
        let visual = model.style.contentSize(model.base)
        let size = CGSize(width: visual.width + Self.margin * 2, height: visual.height + Self.margin * 2)
        var center = center
        if area.width >= visual.width {
            center.x = min(max(center.x, area.minX + visual.width / 2), area.maxX - visual.width / 2)
        }
        if area.height >= visual.height {
            center.y = min(max(center.y, area.minY + visual.height / 2), area.maxY - visual.height / 2)
        }
        panel.setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
    }

    /// Remembers where in the recorded area the bubble sits, for next time.
    private func rememberPosition() {
        guard area.width > 0, area.height > 0 else { return }
        RecordingOptions.cameraPosition = CGPoint(
            x: (center.x - area.minX) / area.width,
            y: (center.y - area.minY) / area.height
        )
    }

    // startRunning/stopRunning block, so they run on the camera queue.
    private func start(_ session: AVCaptureSession) {
        nonisolated(unsafe) let session = session
        queue.async { session.startRunning() }
    }

    private func stop(_ session: AVCaptureSession) {
        nonisolated(unsafe) let session = session
        queue.async { session.stopRunning() }
    }
}
