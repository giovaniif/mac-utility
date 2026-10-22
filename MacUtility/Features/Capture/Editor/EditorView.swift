import SwiftUI

struct EditorView: View {
    enum Action { case save, copy, cancel }

    @Bindable var model: EditorModel
    let onAction: (Action) -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, onAction: onAction)
                .padding(.top, 30) // under the transparent title bar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider()
            EditorCanvas(model: model)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.delete) {
            guard model.editingText == nil, model.selection != nil else { return .ignored }
            withAnimation(.easeOut(duration: 0.15)) { model.deleteSelection() }
            return .handled
        }
        .onKeyPress(.escape) {
            if model.editingText != nil {
                model.finishTextEditing()
            } else if model.selection != nil {
                model.selection = nil
            } else {
                onAction(.cancel)
            }
            return .handled
        }
    }
}

private struct EditorToolbar: View {
    @Bindable var model: EditorModel
    let onAction: (EditorView.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    ToolButton(tool: tool, selected: model.tool == tool) {
                        model.finishTextEditing()
                        withAnimation(.spring(duration: 0.25)) { model.tool = tool }
                        if tool != .select { model.selection = nil }
                    }
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 5) {
                ForEach(Array(EditorModel.palette.enumerated()), id: \.offset) { _, color in
                    Swatch(color: color, selected: model.color == color) {
                        withAnimation(.spring(duration: 0.2)) { model.color = color }
                        model.styleChanged()
                    }
                }
            }

            Picker("Width", selection: $model.lineWidth) {
                Image(systemName: "line.3.horizontal").font(.system(size: 9)).tag(CGFloat(2))
                Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold)).tag(CGFloat(4))
                Image(systemName: "line.3.horizontal").font(.system(size: 15, weight: .heavy)).tag(CGFloat(8))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("Stroke width")
            .onChange(of: model.lineWidth) { model.styleChanged() }

            Spacer(minLength: 8)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .help("Redo")

            Button("Copy") { model.finishTextEditing(); onAction(.copy) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Save") { model.finishTextEditing(); onAction(.save) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(selected ? Color.white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor : hovering ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct Swatch: View {
    let color: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .scaleEffect(hovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.2), value: hovering)
    }
}

/// The screenshot scaled to fit, taking drags in image coordinates.
private struct EditorCanvas: View {
    @Bindable var model: EditorModel
    @State private var dragOrigin: CGPoint?
    @State private var moving: (id: UUID, last: CGPoint)?
    @FocusState private var textFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, proxy.size.width / model.size.width, proxy.size.height / model.size.height)
            let shown = CGSize(width: model.size.width * scale, height: model.size.height * scale)
            ZStack(alignment: .topLeading) {
                EditorRenderView(model: model)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: shown.width, height: shown.height, alignment: .topLeading)
                if let selected = selectedBounds {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: selected.width * scale + 12, height: selected.height * scale + 12)
                        .offset(x: selected.minX * scale - 6, y: selected.minY * scale - 6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if let editing = editingAnnotation {
                    TextField("Type here", text: textBinding(editing.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: editing.fontSize * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(editing.color)
                        .frame(minWidth: 120 * scale, maxWidth: max(shown.width - editing.start.x * scale, 60), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: editing.start.x * scale, y: editing.start.y * scale)
                        .focused($textFocused)
                        .onSubmit { model.finishTextEditing() }
                        .onAppear { textFocused = true }
                }
            }
            .frame(width: shown.width, height: shown.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .contentShape(Rectangle())
            .gesture(drawGesture(scale: scale))
            .onContinuousHover { phase in
                if case .active = phase { cursor.set() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: model.selection)
        }
    }

    private var cursor: NSCursor {
        switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
    }

    private var selectedBounds: CGRect? {
        guard model.tool == .select, let id = model.selection else { return nil }
        return model.annotations.first { $0.id == id }?.bounds
    }

    private var editingAnnotation: Annotation? {
        guard let id = model.editingText else { return nil }
        return model.annotations.first { $0.id == id }
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.annotations.first { $0.id == id }?.text ?? "" },
            set: { text in
                if let index = model.annotations.firstIndex(where: { $0.id == id }) {
                    model.annotations[index].text = text
                }
            }
        )
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), model.size.width), y: min(max(point.y, 0), model.size.height))
    }

    private func drawGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = clamp(CGPoint(x: value.location.x / scale, y: value.location.y / scale))
                if dragOrigin == nil { began(at: point) }
                changed(to: point)
            }
            .onEnded { value in
                let point = clamp(CGPoint(x: value.location.x / scale, y: value.location.y / scale))
                ended(at: point)
                dragOrigin = nil
                moving = nil
            }
    }

    private func began(at point: CGPoint) {
        dragOrigin = point
        if model.editingText != nil {
            model.finishTextEditing()
        }
        switch model.tool {
        case .select:
            let hit = model.annotations.last { $0.hitTest(point) }
            model.selection = hit?.id
            if let hit {
                model.checkpoint()
                moving = (hit.id, point)
            }
        case .crop:
            model.draftCrop = CGRect(origin: point, size: .zero)
        case .text, .counter:
            break
        default:
            guard let kind = model.tool.annotationKind else { return }
            model.draft = Annotation(kind: kind, color: model.color, lineWidth: model.lineWidth, points: [point, point])
        }
    }

    private func changed(to point: CGPoint) {
        guard let origin = dragOrigin else { return }
        switch model.tool {
        case .select:
            guard let current = moving, let index = model.annotations.firstIndex(where: { $0.id == current.id }) else { return }
            let delta = CGSize(width: point.x - current.last.x, height: point.y - current.last.y)
            model.annotations[index] = model.annotations[index].moved(by: delta)
            moving = (current.id, point)
        case .crop:
            model.draftCrop = CGRect(
                x: min(origin.x, point.x), y: min(origin.y, point.y),
                width: abs(point.x - origin.x), height: abs(point.y - origin.y)
            )
        case .pen, .highlighter:
            model.draft?.points.append(point)
        case .text, .counter:
            break
        default:
            model.draft?.points = [origin, point]
        }
    }

    private func ended(at point: CGPoint) {
        switch model.tool {
        case .select:
            break
        case .crop:
            let crop = model.draftCrop
            model.draftCrop = nil
            model.checkpoint()
            withAnimation(.easeOut(duration: 0.2)) {
                // A click without a drag clears the crop.
                model.crop = (crop?.width ?? 0) > 4 && (crop?.height ?? 0) > 4 ? crop : nil
            }
        case .text:
            model.checkpoint()
            let annotation = Annotation(kind: .text, color: model.color, lineWidth: model.lineWidth, points: [point])
            model.annotations.append(annotation)
            model.editingText = annotation.id
        case .counter:
            model.checkpoint()
            var annotation = Annotation(kind: .counter, color: model.color, lineWidth: model.lineWidth, points: [point])
            annotation.number = model.nextCounter
            withAnimation(.spring(duration: 0.25)) { model.annotations.append(annotation) }
        default:
            guard let draft = model.draft else { return }
            model.draft = nil
            let big = draft.bounds.width > 3 || draft.bounds.height > 3
            guard big else { return }
            model.checkpoint()
            model.annotations.append(draft)
        }
    }
}
