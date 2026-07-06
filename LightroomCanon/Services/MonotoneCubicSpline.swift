import Foundation

/// A monotone cubic Hermite spline (Fritsch-Carlson method) — the same
/// smooth, overshoot-free curve interpolation Lightroom's own point curve
/// uses between control points, rather than connecting them with straight
/// lines. The monotonicity constraint (forcing a zero tangent wherever the
/// secant slope changes sign) is what keeps the curve from ringing/
/// overshooting past a control point between two points of the same slope
/// direction — important for a tone curve specifically, since an ordinary
/// (non-monotone) spline can otherwise invert brightness order near a steep
/// point.
///
/// Two call sites use this: `XMPPresetParser.sampleCurve` (reproducing
/// Adobe's actual curve shape when importing a preset, instead of a cruder
/// straight-line approximation) and `ToneCurveView`'s preview path (so the
/// on-screen curve matches what `CIToneCurve` actually renders — it's also
/// spline-interpolated between its 5 points, not straight segments).
struct MonotoneCubicSpline {
    private let xs: [Double]
    private let ys: [Double]
    private let tangents: [Double]

    /// `points` need not be pre-sorted or deduplicated. If they don't already
    /// reach `domainMin`/`domainMax`, this extends flat from the outermost
    /// point to that boundary — matching how a tone curve behaves outside
    /// its defined control points.
    init(points: [(x: Double, y: Double)], domainMin: Double = 0, domainMax: Double = 255) {
        let sorted = points.sorted { $0.x < $1.x }
        var unique: [(x: Double, y: Double)] = []
        for p in sorted where unique.last?.x != p.x {
            unique.append(p)
        }
        if let first = unique.first, first.x > domainMin {
            unique.insert((domainMin, first.y), at: 0)
        }
        if let last = unique.last, last.x < domainMax {
            unique.append((domainMax, last.y))
        }

        let x = unique.map(\.x)
        let y = unique.map(\.y)
        let n = x.count
        xs = x
        ys = y

        guard n >= 2 else {
            tangents = Array(repeating: 0, count: n)
            return
        }

        var dx = [Double](repeating: 0, count: n - 1)
        var slopes = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            dx[i] = x[i + 1] - x[i]
            slopes[i] = dx[i] != 0 ? (y[i + 1] - y[i]) / dx[i] : 0
        }

        var t = [Double](repeating: 0, count: n)
        t[0] = slopes[0]
        t[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            let m0 = slopes[i - 1], m1 = slopes[i]
            if m0 * m1 <= 0 {
                // Secant slope changes sign (a local min/max at this
                // control point) — force a flat tangent to prevent overshoot.
                t[i] = 0
            } else {
                let h0 = dx[i - 1], h1 = dx[i]
                t[i] = (3 * (h0 + h1)) / ((2 * h1 + h0) / m0 + (2 * h0 + h1) / m1)
            }
        }
        tangents = t
    }

    /// The interpolated y for a given x, clamped flat beyond the outermost
    /// control points.
    func evaluate(at targetX: Double) -> Double {
        guard xs.count >= 2 else { return ys.first ?? targetX }
        if targetX <= xs[0] { return ys[0] }
        if targetX >= xs[xs.count - 1] { return ys[ys.count - 1] }

        var index = 0
        for i in 0..<(xs.count - 1) where targetX >= xs[i] && targetX <= xs[i + 1] {
            index = i
            break
        }

        let x0 = xs[index], x1 = xs[index + 1]
        let y0 = ys[index], y1 = ys[index + 1]
        let m0 = tangents[index], m1 = tangents[index + 1]
        let h = x1 - x0
        guard h != 0 else { return y0 }

        let t = (targetX - x0) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        return h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1
    }
}
