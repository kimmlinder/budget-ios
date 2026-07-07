import CoreImage
import Foundation

/// Recombines a full-color image with a separately luminance-processed
/// version of it, so an operation like Texture/Clarity's local-contrast
/// enhancement only ever changes lightness — never hue or saturation.
///
/// `CIUnsharpMask` (what actually drives Texture/Clarity in
/// `RAWProcessor.applyLocalContrast`) operates on R, G, and B independently.
/// Sharpening each channel separately amplifies whatever difference already
/// exists between them at an edge, which shows up as colored fringing and
/// over-saturated edges — a real, visible way this pipeline diverged from
/// Lightroom's Texture/Clarity, which only ever pushes local *lightness*
/// contrast and leaves color alone. Same principle as `LuminanceContrastKernel`
/// and `HighlightRolloffKernel`, applied to a two-image blend instead of a
/// single-image scale.
///
/// This also tapers the effect toward zero near black and white (full
/// strength only at mid-gray). Lightroom's Clarity/Texture mostly leave
/// shadows and highlights alone; applying an unsharp mask at full strength
/// across the *entire* tonal range — including near-clipped skies and deep
/// shadows — is what makes local-contrast boosts read as harsh/clipped
/// instead of a gentle punch.
enum LuminanceBlendKernel {
    static let shared: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first as? CIColorKernel
    }()

    /// `enhancedLuma` must be a same-extent, luminance-only (R == G == B)
    /// version of `original` that's already had the desired processing
    /// (e.g. an unsharp mask or blur) applied to it.
    static func apply(original: CIImage, enhancedLuma: CIImage) -> CIImage {
        guard let kernel = shared else { return original }
        return kernel.apply(extent: original.extent, arguments: [original, enhancedLuma]) ?? original
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" float4 luminanceBlend(
        coreimage::sample_t original, coreimage::sample_t enhancedLuma, coreimage::destination dest
    ) [[ stitchable ]] {
        float origLuma = dot(original.rgb, float3(0.2126, 0.7152, 0.0722));
        if (origLuma <= 0.0001) {
            return original;
        }
        // Smooth 0...1...0 curve peaking at mid-gray (origLuma == 0.5) and
        // reaching 0 at pure black/white, so the enhancement fades out
        // completely at the tonal extremes instead of clipping/haloing there.
        float midtoneWeight = sin(3.14159265 * clamp(origLuma, 0.0, 1.0));
        float effectiveLuma = mix(origLuma, enhancedLuma.r, midtoneWeight);
        float scale = effectiveLuma / origLuma;
        return float4(original.rgb * scale, original.a);
    }
    """
}
