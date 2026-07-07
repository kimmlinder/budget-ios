import CoreImage
import Foundation

/// Contrast applied to luminance only, preserving each pixel's color ratio —
/// matching how Lightroom's Contrast slider keeps the image looking natural
/// at high values instead of the "neon" over-saturation a naive per-channel
/// RGB contrast produces.
///
/// `CIColorControls`' own `contrast` scales R, G, and B independently around
/// the same 0.5 pivot. For an already-saturated pixel (channels far apart),
/// that widens the gap between channels as a side effect, which reads as
/// *more* saturated — contrast and saturation become entangled. Computing
/// luma, applying the contrast curve to just that value, then scaling all
/// three channels by the resulting ratio (the same technique
/// `HighlightRolloffKernel` uses for its highlight knee) changes brightness
/// only; the pixel's hue and saturation are untouched.
enum LuminanceContrastKernel {
    static let shared: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first as? CIColorKernel
    }()

    /// `contrast` uses the same convention as `CIColorControls.contrast`:
    /// 1.0 = no change, <1 flattens, >1 punches up.
    static func apply(to image: CIImage, contrast: Float) -> CIImage {
        guard contrast != 1, let kernel = shared else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, contrast]) ?? image
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" float4 luminanceContrast(
        coreimage::sample_t s, float contrast, coreimage::destination dest
    ) [[ stitchable ]] {
        // Rec. 709 luma weights — correct for gamma-encoded (non-linear)
        // R'G'B', which is the space this pipeline already works in.
        float luma = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
        if (luma <= 0.0) {
            return s;
        }
        float adjustedLuma = (luma - 0.5) * contrast + 0.5;
        float scale = max(0.0, adjustedLuma) / luma;
        return float4(s.rgb * scale, s.a);
    }
    """
}
