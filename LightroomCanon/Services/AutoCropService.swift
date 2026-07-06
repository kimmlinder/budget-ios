import CoreImage
import Foundation

/// Finds a crop that trims the transparent, ragged corners a keystone/
/// perspective warp leaves behind — Core Image doesn't crop those itself
/// (verified empirically: the warped-away corners render with alpha 0).
///
/// The exact boundary of a Keystone Correction's output isn't a shape Apple
/// documents a formula for (it's a 3D-modeled warp, not a plain homography),
/// so this works empirically instead: rasterize the corrected image's alpha
/// channel at low resolution, then find the largest axis-aligned rectangle of
/// fully-opaque pixels via the standard "maximal rectangle in a binary
/// matrix" algorithm (a histogram-based approach, O(rows × cols)).
enum AutoCropService {
    /// The largest fully-opaque rectangle in `image`, as a normalized crop
    /// rect matching `AdjustmentValues`' convention (0...1, origin top-left).
    /// `nil` if the image has no opaque content at all.
    static func largestOpaqueRect(in image: CIImage, resolution: Int = 200) -> CGRect? {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }

        let scale = CGFloat(resolution) / max(e.width, e.height)
        let cols = max(1, Int((e.width * scale).rounded()))
        let rows = max(1, Int((e.height * scale).rounded()))

        // Render into a top-left-origin cols×rows bitmap.
        let normalized = image
            .transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var buffer = [UInt8](repeating: 0, count: cols * rows * 4)
        RenderEngine.context.render(
            normalized, toBitmap: &buffer, rowBytes: cols * 4,
            bounds: CGRect(x: 0, y: 0, width: cols, height: rows),
            format: .RGBA8, colorSpace: nil
        )

        var opaque = [[Bool]](repeating: [Bool](repeating: false, count: cols), count: rows)
        for r in 0..<rows {
            for c in 0..<cols {
                opaque[r][c] = buffer[(r * cols + c) * 4 + 3] == 255
            }
        }

        guard let best = largestRectangle(in: opaque) else { return nil }
        return CGRect(
            x: Double(best.left) / Double(cols),
            y: Double(best.top) / Double(rows),
            width: Double(best.right - best.left + 1) / Double(cols),
            height: Double(best.bottom - best.top + 1) / Double(rows)
        )
    }

    private struct PixelRect { var top: Int; var bottom: Int; var left: Int; var right: Int }

    /// Classic maximal-rectangle-in-binary-matrix: track each column's
    /// consecutive-opaque run as a "height", and for every row solve largest-
    /// rectangle-in-histogram with a monotonic stack.
    private static func largestRectangle(in opaque: [[Bool]]) -> PixelRect? {
        let rows = opaque.count
        guard rows > 0, let cols = opaque.first?.count, cols > 0 else { return nil }

        var heights = [Int](repeating: 0, count: cols)
        var best: (area: Int, rect: PixelRect)?

        for r in 0..<rows {
            for c in 0..<cols {
                heights[c] = opaque[r][c] ? heights[c] + 1 : 0
            }
            var stack: [Int] = []
            for c in 0...cols {
                let h = c < cols ? heights[c] : 0
                while let last = stack.last, heights[last] >= h {
                    stack.removeLast()
                    let height = heights[last]
                    let left = stack.isEmpty ? 0 : stack[stack.count - 1] + 1
                    let right = c - 1
                    let area = height * (right - left + 1)
                    if best == nil || area > best!.area {
                        best = (area, PixelRect(top: r - height + 1, bottom: r, left: left, right: right))
                    }
                }
                stack.append(c)
            }
        }
        return best?.rect
    }
}
