import AppKit
import Observation
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, counter, pixelate, crop

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "squareshape.split.3x3"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "Select and move"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .counter: "Numbered step"
        case .pixelate: "Pixelate"
        case .crop: "Crop"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlighter: .highlighter
        case .text: .text
        case .counter: .counter
        case .pixelate: .pixelate
        case .select, .crop: nil
        }
    }
}

@MainActor
@Observable
final class EditorModel {
    let image: NSImage
    let pixelated: NSImage?
    /// Screenshot size in points.
    let size: CGSize

    var annotations: [Annotation] = []
    var crop: CGRect?
    var tool: EditorTool = .arrow
    var color: Color = .red
    var lineWidth: CGFloat = 4
    var selection: UUID?
    var editingText: UUID?
    /// Shape being drawn right now, before it's committed.
    var draft: Annotation?
    var draftCrop: CGRect?

    private var undoStack: [(annotations: [Annotation], crop: CGRect?)] = []
    private var redoStack: [(annotations: [Annotation], crop: CGRect?)] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    init(image: NSImage) {
        self.image = image
        size = image.size
        pixelated = Self.pixelate(image)
    }

    var nextCounter: Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    func checkpoint() {
        undoStack.append((annotations, crop))
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((annotations, crop))
        annotations = last.annotations
        crop = last.crop
        selection = nil
        editingText = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((annotations, crop))
        annotations = next.annotations
        crop = next.crop
        selection = nil
    }

    func deleteSelection() {
        guard let selection else { return }
        checkpoint()
        annotations.removeAll { $0.id == selection }
        self.selection = nil
    }

    /// Applies the current color or width to the selected mark too.
    func styleChanged() {
        guard let selection, let index = annotations.firstIndex(where: { $0.id == selection }) else { return }
        checkpoint()
        annotations[index].color = color
        annotations[index].lineWidth = lineWidth
    }

    func finishTextEditing() {
        guard let id = editingText else { return }
        editingText = nil
        if let index = annotations.firstIndex(where: { $0.id == id }),
           annotations[index].text.trimmingCharacters(in: .whitespaces).isEmpty {
            annotations.remove(at: index)
        }
    }

    /// Flattens the marks onto the screenshot at full resolution.
    func render() -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cgImage.width) / size.width
        let renderer = ImageRenderer(content: EditorRenderView(model: self, includeCropMask: false))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard var output = renderer.cgImage else { return nil }
        if let crop, crop.width >= 2, crop.height >= 2 {
            let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
            output = output.cropping(to: pixels) ?? output
        }
        return NSImage(cgImage: output, size: NSSize(width: CGFloat(output.width) / scale, height: CGFloat(output.height) / scale))
    }

    /// Shrinks the screenshot to blocks and scales it back up without
    /// smoothing, which gives the classic mosaic.
    private static func pixelate(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let block = max(CGFloat(cgImage.width) / 60, 14)
        let smallWidth = max(Int(CGFloat(cgImage.width) / block), 1)
        let smallHeight = max(Int(CGFloat(cgImage.height) / block), 1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
              let large = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        small.interpolationQuality = .medium
        small.draw(cgImage, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let blocks = small.makeImage() else { return nil }
        large.interpolationQuality = .none
        large.draw(blocks, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let result = large.makeImage() else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }
}

/// Screenshot plus marks at image size. Used both on screen (scaled) and for
/// the final render, so what you see is what gets saved.
struct EditorRenderView: View {
    let model: EditorModel
    var includeCropMask = true

    var body: some View {
        let pixelated = model.pixelated.map { Image(nsImage: $0) }
        ZStack(alignment: .topLeading) {
            Image(nsImage: model.image)
                .resizable()
                .frame(width: model.size.width, height: model.size.height)
            Canvas { context, _ in
                for annotation in model.annotations where annotation.id != model.editingText {
                    annotation.draw(in: &context, pixelated: pixelated, imageSize: model.size)
                }
                model.draft?.draw(in: &context, pixelated: pixelated, imageSize: model.size)
            }
            .frame(width: model.size.width, height: model.size.height)
            if includeCropMask, let crop = model.draftCrop ?? model.crop {
                CropMask(crop: crop, size: model.size)
            }
        }
        .frame(width: model.size.width, height: model.size.height)
    }
}

private struct CropMask: View {
    let crop: CGRect
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(crop)
            context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            context.stroke(Path(crop), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .allowsHitTesting(false)
    }
}

/// Opens screenshots in an editor window; saves back to the same file.
@MainActor
final class ScreenshotEditor {
    private var windows: [URL: NSWindow] = [:]

    func open(_ url: URL, onSave: @escaping @MainActor (URL, NSImage) -> Void) {
        if let window = windows[url] {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let image = NSImage(contentsOf: url) else { return }
        // Keep the screenshot's point size (PNG DPI) so Retina captures edit at real size.
        if let rep = image.representations.first {
            image.size = NSSize(width: rep.size.width, height: rep.size.height)
        }
        let model = EditorModel(image: image)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 480)

        let close: @MainActor () -> Void = { [weak self, weak window] in
            window?.close()
            self?.windows[url] = nil
        }
        let view = EditorView(model: model) { action in
            switch action {
            case .save:
                guard let output = model.render(), Self.writePNG(output, to: url) else {
                    HUD.show("Couldn't save the screenshot")
                    return
                }
                onSave(url, output)
                close()
            case .copy:
                guard let output = model.render() else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([output])
                HUD.show("Copied")
                close()
            case .cancel:
                close()
            }
        }
        window.contentView = NSView.hosting(view)

        let screen = NSScreen.underMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let chrome = CGSize(width: 40, height: 120)
        let fit = min(1, (visible.width * 0.85 - chrome.width) / model.size.width, (visible.height * 0.85 - chrome.height) / model.size.height)
        let size = NSSize(
            width: max(model.size.width * fit + chrome.width, 980),
            height: max(model.size.height * fit + chrome.height, 480)
        )
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        windows[url] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.alphaValue = 0
        window.fadeIn(duration: 0.18)
    }

    #if DEBUG
    /// Draws one of every mark on `input` and saves the render to `output`.
    static func renderSample(_ input: URL, to output: URL) {
        guard let image = NSImage(contentsOf: input) else { return }
        if let rep = image.representations.first { image.size = rep.size }
        let model = EditorModel(image: image)
        let w = model.size.width, h = model.size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
        model.annotations = [
            Annotation(kind: .arrow, color: .red, lineWidth: 4, points: [p(0.1, 0.1), p(0.35, 0.35)]),
            Annotation(kind: .rectangle, color: .green, lineWidth: 4, points: [p(0.45, 0.1), p(0.7, 0.3)]),
            Annotation(kind: .ellipse, color: .orange, lineWidth: 8, points: [p(0.75, 0.1), p(0.95, 0.3)]),
            Annotation(kind: .line, color: .purple, lineWidth: 2, points: [p(0.1, 0.9), p(0.4, 0.8)]),
            Annotation(kind: .pen, color: .blue, lineWidth: 4, points: (0..<40).map { p(0.5 + CGFloat($0) / 120, 0.85 + 0.05 * sin(CGFloat($0) / 4)) }),
            Annotation(kind: .highlighter, color: .yellow, lineWidth: 4, points: [p(0.12, 0.42), p(0.6, 0.42)]),
            Annotation(kind: .pixelate, color: .red, lineWidth: 4, points: [p(0.55, 0.35), p(0.85, 0.5)]),
            Annotation(kind: .text, color: .red, lineWidth: 8, points: [p(0.1, 0.6)], text: "Hello editor"),
            Annotation(kind: .counter, color: .blue, lineWidth: 4, points: [p(0.9, 0.7)], number: 1),
            Annotation(kind: .counter, color: .blue, lineWidth: 4, points: [p(0.9, 0.85)], number: 2),
        ]
        model.crop = CGRect(x: w * 0.02, y: h * 0.02, width: w * 0.96, height: h * 0.96)
        if let rendered = model.render() { _ = writePNG(rendered, to: output) }
    }
    #endif

    private static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
