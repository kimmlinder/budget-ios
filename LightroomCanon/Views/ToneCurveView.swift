import SwiftUI

/// A 5-point, Lightroom-style tone curve editor. X positions are fixed
/// (shadows / quarter / mid / three-quarter / highlights); dragging a handle
/// moves only its Y value. The five points map directly onto `CIToneCurve`'s
/// point0...point4, so what you see here is exactly what gets rendered.
///
/// Only the two endpoint anchors (black point, white point) show a handle by
/// default, matching Lightroom's own point curve — the three middle points
/// stay invisible while they sit on the identity diagonal, and only appear
/// once actually dragged off it. `CIToneCurve` itself always needs all 5
/// values regardless, so this is purely a presentation difference: the
/// middle points are real from the start, just not drawn until adjusted.
struct ToneCurveView: View {
    @Binding var points: [Double]
    /// Tints the curve line and handles — used to distinguish the Red/Green/
    /// Blue channel curves from the master RGB curve (white) and from each
    /// other, matching Lightroom's own Tone Curve panel convention.
    var color: Color = .white

    private static let xPositions = AdjustmentValues.toneCurveIdentity
    private let handleSize: CGFloat = 14

    /// Each handle's Y value when its current drag gesture began, so we can
    /// anchor to a fixed reference point and add the gesture's cumulative
    /// translation — mutating `points[index]` mid-drag while also reading it
    /// as the anchor would double-apply movement and make the handle run away.
    @State private var dragStartValues: [Int: Double] = [:]
    /// Which currently-hidden middle point a background drag (one that
    /// didn't start on an already-visible handle) is revealing/adjusting.
    @State private var activeMiddleIndex: Int?

    /// The two endpoints (always shown, like Lightroom's own fixed anchors)
    /// plus any middle point that's been moved off the identity diagonal.
    private var visibleIndices: [Int] {
        (0..<points.count).filter { i in
            i == 0 || i == points.count - 1 || points[i] != Self.xPositions[i]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                gridLines(size: size)
                diagonal(size: size)
                curvePath(size: size)
                    .stroke(color, lineWidth: 2)
                // Catches drags on any part of the curve that doesn't
                // already have a visible handle, and reveals/adjusts the
                // nearest hidden middle point — sits below the handles below
                // so a drag starting exactly on one of those still goes to
                // its own gesture instead.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(middlePointDrag(size: size))
                ForEach(visibleIndices, id: \.self) { i in
                    handle(index: i, size: size)
                }
            }
        }
        .frame(height: 200)
        .padding(8)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(count: 2) { points = AdjustmentValues.toneCurveIdentity }
    }

    private func middlePointDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let index = activeMiddleIndex ?? nearestMiddleIndex(toX: drag.startLocation.x, size: size)
                activeMiddleIndex = index
                guard let index else { return }
                let start = dragStartValues[index] ?? points[index]
                dragStartValues[index] = start
                let startY = (1 - start) * size.height
                let newY = startY + drag.translation.height
                points[index] = min(1, max(0, 1 - newY / size.height))
            }
            .onEnded { _ in
                if let index = activeMiddleIndex { dragStartValues[index] = nil }
                activeMiddleIndex = nil
            }
    }

    /// The middle point (excluding the two fixed endpoints) whose x-position
    /// is closest to where a background drag began.
    private func nearestMiddleIndex(toX x: CGFloat, size: CGSize) -> Int? {
        guard points.count > 2 else { return nil }
        return (1..<(points.count - 1)).min {
            abs(Self.xPositions[$0] * size.width - x) < abs(Self.xPositions[$1] * size.width - x)
        }
    }

    private func location(for index: Int, size: CGSize) -> CGPoint {
        CGPoint(x: Self.xPositions[index] * size.width,
                y: (1 - points[index]) * size.height)
    }

    /// Sampled from a `MonotoneCubicSpline` through the same 5 points
    /// `CIToneCurve` renders from, rather than straight segments between
    /// them — `CIToneCurve` is itself spline-interpolated, so straight lines
    /// here would show a visibly different shape than what actually renders.
    private func curvePath(size: CGSize) -> Path {
        let controlPoints = points.indices.map { (x: Self.xPositions[$0], y: points[$0]) }
        let spline = MonotoneCubicSpline(points: controlPoints, domainMin: 0, domainMax: 1)
        var path = Path()
        let steps = 60
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let y = spline.evaluate(at: t)
            let point = CGPoint(x: t * size.width, y: (1 - y) * size.height)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func diagonal(size: CGSize) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height))
            p.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    private func gridLines(size: CGSize) -> some View {
        Path { p in
            for f in [0.25, 0.5, 0.75] {
                p.move(to: CGPoint(x: size.width * f, y: 0))
                p.addLine(to: CGPoint(x: size.width * f, y: size.height))
                p.move(to: CGPoint(x: 0, y: size.height * f))
                p.addLine(to: CGPoint(x: size.width, y: size.height * f))
            }
        }
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }

    private func handle(index: Int, size: CGSize) -> some View {
        ZStack {
            Circle().fill(color).frame(width: handleSize, height: handleSize)
        }
        .frame(width: handleSize * 2, height: handleSize * 2)
        .contentShape(Circle())
        .position(location(for: index, size: size))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStartValues[index] ?? points[index]
                    dragStartValues[index] = start
                    let startY = (1 - start) * size.height
                    let newY = startY + drag.translation.height
                    points[index] = min(1, max(0, 1 - newY / size.height))
                }
                .onEnded { _ in dragStartValues[index] = nil }
        )
    }
}

#Preview {
    struct Wrapper: View {
        @State private var points = AdjustmentValues.toneCurveIdentity
        var body: some View { ToneCurveView(points: $points).padding() }
    }
    return Wrapper()
}
