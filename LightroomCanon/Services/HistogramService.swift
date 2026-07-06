import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Normalized (0...1) per-channel bin heights for an RGB histogram.
struct HistogramData: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
}

/// Computes an RGB histogram reflecting a preview's current tonal
/// distribution, for display in the editor.
enum HistogramService {
    static let binCount = 256

    /// Reads back the raw per-channel bin counts from `CIAreaHistogram` and
    /// normalizes them for display. The source is downsampled first — only
    /// the overall shape matters, which keeps this cheap enough to recompute
    /// on every slider change. Normalization uses a square-root curve so a
    /// single tall spike (a flat sky, a black border) doesn't crush the rest
    /// of the tonal range down to invisible slivers, matching how Lightroom's
    /// own histogram reads.
    static func makeHistogram(for source: CIImage) -> HistogramData? {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let maxDimension: CGFloat = 256
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let sample = scale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source

        let areaHistogram = CIFilter.areaHistogram()
        areaHistogram.inputImage = sample
        areaHistogram.extent = sample.extent
        areaHistogram.count = binCount
        areaHistogram.scale = 1.0
        guard let histogramImage = areaHistogram.outputImage else { return nil }

        // The output is one pixel tall; each pixel's RGBA components hold
        // that bin's (redCount, greenCount, blueCount, alphaCount).
        var buffer = [Float](repeating: 0, count: binCount * 4)
        buffer.withUnsafeMutableBytes { ptr in
            RenderEngine.context.render(
                histogramImage,
                toBitmap: ptr.baseAddress!,
                rowBytes: binCount * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: binCount, height: 1),
                format: .RGBAf,
                colorSpace: nil
            )
        }

        var red = [Float](repeating: 0, count: binCount)
        var green = [Float](repeating: 0, count: binCount)
        var blue = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            red[i] = buffer[i * 4]
            green[i] = buffer[i * 4 + 1]
            blue[i] = buffer[i * 4 + 2]
        }

        let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0, 0.000_001)
        func normalize(_ bins: [Float]) -> [Float] { bins.map { sqrt($0 / peak) } }
        return HistogramData(red: normalize(red), green: normalize(green), blue: normalize(blue))
    }
}
