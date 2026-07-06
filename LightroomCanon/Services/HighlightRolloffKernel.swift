import CoreImage
import Foundation

/// A gentle, always-on highlight shoulder — simulates how film (and
/// Lightroom's own default tone response) lets bright areas fade smoothly
/// toward white instead of clipping flat and gray the way a bare
/// `CIExposureAdjust`/linear scale does.
///
/// Crucially, this compresses all three channels by the *same* factor
/// (derived from the brightest channel), rather than applying a curve to
/// each channel independently. Independent per-channel compression is what
/// causes near-clipped highlights to shift hue (e.g. skin tones drifting
/// orange/yellow as exposure goes up) — scaling uniformly preserves the
/// pixel's color ratio and only reduces its brightness.
enum HighlightRolloffKernel {
    static let shared: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first as? CIColorKernel
    }()

    /// Compresses values above `threshold` with a Reinhard-style knee
    /// (`threshold + excess / (1 + excess)`), which approaches but never
    /// reaches 1.0 no matter how far over `threshold` the input is — this is
    /// what actually preserves highlight detail (a soft roll-off) instead of
    /// a hard clip. Below `threshold`, the image passes through unchanged.
    static func apply(to image: CIImage, threshold: Float = 0.8) -> CIImage {
        guard let kernel = shared else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, threshold]) ?? image
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" float4 highlightRolloff(
        coreimage::sample_t s, float threshold, coreimage::destination dest
    ) [[ stitchable ]] {
        float m = max(s.r, max(s.g, s.b));
        if (m <= threshold || m <= 0.0) {
            return s;
        }
        float excess = m - threshold;
        float compressed = threshold + excess / (1.0 + excess);
        float scale = compressed / m;
        return float4(s.r * scale, s.g * scale, s.b * scale, s.a);
    }
    """
}
