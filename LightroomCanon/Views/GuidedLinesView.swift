import SwiftUI

/// Drag-to-draw overlay for Guided Upright: place up to 4 lines along edges
/// that should be vertical or horizontal. `GuidedGeometry` turns whatever's
/// drawn into a correction once there are 2 lines of one orientation (or 2 of
/// each). Must be sized to exactly the rendered image's rect within the
/// preview — see `EditorView.previewArea`, which computes that rect the same
/// way `MetalImageView` aspect-fits the image.
struct GuidedLinesView: View {
    @Binding var lines: [GuideLine]

    private static let maxLines = 4
    private static let minDragDistance: CGFloat = 12

    @State private var draftEnd: CGPoint?
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.white.opacity(0.001)  // makes the whole area draggable
                ForEach(lines) { line in
                    lineView(line, size: size, color: .yellow)
                }
                if let dragStart, let draftEnd {
                    lineView(
                        GuideLine(start: normalized(dragStart, size: size), end: normalized(draftEnd, size: size)),
                        size: size, color: .yellow.opacity(0.6)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard lines.count < Self.maxLines else { return }
                        if dragStart == nil { dragStart = drag.startLocation }
                        draftEnd = drag.location
                    }
                    .onEnded { drag in
                        defer { dragStart = nil; draftEnd = nil }
                        guard lines.count < Self.maxLines,
                              hypot(drag.translation.width, drag.translation.height) > Self.minDragDistance
                        else { return }
                        lines.append(GuideLine(
                            start: normalized(drag.startLocation, size: size),
                            end: normalized(drag.location, size: size)
                        ))
                    }
            )
        }
    }

    /// View-space (top-left origin) -> stored space (bottom-left origin,
    /// matching Core Image/Vision), normalized 0...1 and clamped to the frame.
    private func normalized(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, 1 - p.y / size.height)))
    }

    private func viewPoint(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private func lineView(_ line: GuideLine, size: CGSize, color: Color) -> some View {
        let p1 = viewPoint(line.start, size: size)
        let p2 = viewPoint(line.end, size: size)
        return ZStack {
            Path { path in
                path.move(to: p1)
                path.addLine(to: p2)
            }
            .stroke(color, lineWidth: 2)
            Circle().fill(color).frame(width: 10, height: 10).position(p1)
            Circle().fill(color).frame(width: 10, height: 10).position(p2)
        }
    }
}
