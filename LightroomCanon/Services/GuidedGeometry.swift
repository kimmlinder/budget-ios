import CoreGraphics

/// Turns the user's drawn guide lines into a `GeometryCorrectionKind` +
/// 4-corner quad for `RAWProcessor`. Lines are treated as infinite (not just
/// the drawn segment) when intersected, matching how Lightroom's Guided
/// Upright extrapolates short guides drawn along an edge.
///
/// All points here — guide lines and the resulting corners — are normalized
/// (0...1) in Core Image's bottom-left-origin convention (y increases
/// upward), matching `AdjustmentValues.geometryCorners`.
enum GuidedGeometry {
    /// `nil` until there are exactly 2 lines of one orientation, or exactly 2
    /// of each. More than that (e.g. 3 verticals) is treated as ambiguous.
    static func resolve(_ lines: [GuideLine]) -> (kind: GeometryCorrectionKind, corners: [CGPoint])? {
        let verticals = lines.filter(\.isVertical)
        let horizontals = lines.filter { !$0.isVertical }

        if verticals.count == 2, horizontals.count == 2 {
            return combined(verticals: verticals, horizontals: horizontals)
        } else if verticals.count == 2, horizontals.isEmpty {
            return verticalOnly(verticals)
        } else if horizontals.count == 2, verticals.isEmpty {
            return horizontalOnly(horizontals)
        }
        return nil
    }

    private static func verticalOnly(_ lines: [GuideLine]) -> (GeometryCorrectionKind, [CGPoint]) {
        let ordered = lines.sorted { midX($0) < midX($1) }
        let left = ordered[0], right = ordered[1]
        let leftTop = topPoint(left), leftBottom = bottomPoint(left)
        let rightTop = topPoint(right), rightBottom = bottomPoint(right)
        return (.vertical, [leftTop, rightTop, rightBottom, leftBottom])
    }

    private static func horizontalOnly(_ lines: [GuideLine]) -> (GeometryCorrectionKind, [CGPoint]) {
        let ordered = lines.sorted { midY($0) > midY($1) }  // y increases upward -> first is top
        let top = ordered[0], bottom = ordered[1]
        let topLeft = leftPoint(top), topRight = rightPoint(top)
        let bottomLeft = leftPoint(bottom), bottomRight = rightPoint(bottom)
        return (.horizontal, [topLeft, topRight, bottomRight, bottomLeft])
    }

    private static func combined(
        verticals: [GuideLine], horizontals: [GuideLine]
    ) -> (GeometryCorrectionKind, [CGPoint])? {
        let vOrdered = verticals.sorted { midX($0) < midX($1) }
        let hOrdered = horizontals.sorted { midY($0) > midY($1) }
        let left = vOrdered[0], right = vOrdered[1]
        let top = hOrdered[0], bottom = hOrdered[1]
        guard let topLeft = intersection(left, top),
              let topRight = intersection(right, top),
              let bottomRight = intersection(right, bottom),
              let bottomLeft = intersection(left, bottom)
        else { return nil }
        return (.combined, [topLeft, topRight, bottomRight, bottomLeft])
    }

    private static func midX(_ l: GuideLine) -> Double { (l.start.x + l.end.x) / 2 }
    private static func midY(_ l: GuideLine) -> Double { (l.start.y + l.end.y) / 2 }
    private static func topPoint(_ l: GuideLine) -> CGPoint { l.start.y >= l.end.y ? l.start : l.end }
    private static func bottomPoint(_ l: GuideLine) -> CGPoint { l.start.y >= l.end.y ? l.end : l.start }
    private static func rightPoint(_ l: GuideLine) -> CGPoint { l.start.x >= l.end.x ? l.start : l.end }
    private static func leftPoint(_ l: GuideLine) -> CGPoint { l.start.x >= l.end.x ? l.end : l.start }

    /// Intersects two lines extended to infinity through their two points.
    private static func intersection(_ a: GuideLine, _ b: GuideLine) -> CGPoint? {
        let (x1, y1, x2, y2) = (a.start.x, a.start.y, a.end.x, a.end.y)
        let (x3, y3, x4, y4) = (b.start.x, b.start.y, b.end.x, b.end.y)
        let denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        guard abs(denom) > 1e-9 else { return nil }
        let a1 = x1 * y2 - y1 * x2
        let a2 = x3 * y4 - y3 * x4
        let px = (a1 * (x3 - x4) - (x1 - x2) * a2) / denom
        let py = (a1 * (y3 - y4) - (y1 - y2) * a2) / denom
        return CGPoint(x: px, y: py)
    }
}
