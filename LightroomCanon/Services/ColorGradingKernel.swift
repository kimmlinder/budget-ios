import CoreImage
import Foundation

/// Tints shadows, midtones, and highlights independently, plus an overall
/// Global tint — matching Lightroom's current Color Grading panel (which
/// replaced the older 2-wheel Split Toning panel).
///
/// This is a documented approximation, not a reproduction of Adobe's exact
/// (undocumented) crossover/blending math — same spirit as
/// `RAWProcessor.applyCalibration`. Each pixel's HSL lightness determines how
/// much it belongs to the shadow/midtone/highlight zone (a smooth partition
/// of unity, not a hard cutoff); `balance` shifts the shadow/highlight
/// crossover point up or down. Each zone's (hue, saturation) contributes to a
/// combined target hue — blended as unit vectors so opposite hues don't
/// cancel out at the wrong angle — and the pixel's hue is shifted toward that
/// target by an amount driven by the zones' saturations and the overall
/// `blending` (effect strength) slider. Luminance shifts are blended the same
/// way. Working in HSL (rather than per-channel RGB, like a naive tint)
/// keeps this from shifting saturation/brightness in ways unrelated to the
/// actual grade — the same reasoning behind every other luminance-preserving
/// kernel in this file.
enum ColorGradingKernel {
    static let shared: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first as? CIColorKernel
    }()

    /// One color-wheel position: `hue` 0...360, `saturation` 0...100,
    /// `luminance` -100...100.
    struct Zone {
        var hue: Double
        var saturation: Double
        var luminance: Double
    }

    static func apply(
        to image: CIImage, shadow: Zone, midtone: Zone, highlight: Zone, global: Zone,
        blending: Double, balance: Double
    ) -> CIImage {
        guard let kernel = shared else { return image }
        func vector(_ z: Zone) -> CIVector {
            CIVector(x: z.hue / 360, y: z.saturation / 100, z: z.luminance / 100)
        }
        let args: [Any] = [
            image, vector(shadow), vector(midtone), vector(highlight), vector(global),
            Float(blending / 100), Float(balance),
        ]
        return kernel.apply(extent: image.extent, arguments: args) ?? image
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    static float3 rgb2hsl(float3 c) {
        float maxc = max(c.r, max(c.g, c.b));
        float minc = min(c.r, min(c.g, c.b));
        float l = (maxc + minc) * 0.5;
        float h = 0.0;
        float s = 0.0;
        float d = maxc - minc;
        if (d > 1e-6) {
            s = l < 0.5 ? d / (maxc + minc) : d / (2.0 - maxc - minc);
            if (maxc == c.r) {
                h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
            } else if (maxc == c.g) {
                h = (c.b - c.r) / d + 2.0;
            } else {
                h = (c.r - c.g) / d + 4.0;
            }
            h /= 6.0;
        }
        return float3(h, s, l);
    }

    static float hue2rgb(float p, float q, float t) {
        if (t < 0.0) t += 1.0;
        if (t > 1.0) t -= 1.0;
        if (t < 1.0/6.0) return p + (q - p) * 6.0 * t;
        if (t < 1.0/2.0) return q;
        if (t < 2.0/3.0) return p + (q - p) * (2.0/3.0 - t) * 6.0;
        return p;
    }

    static float3 hsl2rgb(float3 hsl) {
        float h = hsl.x, s = hsl.y, l = hsl.z;
        if (s <= 1e-6) return float3(l, l, l);
        float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
        float p = 2.0 * l - q;
        return float3(
            hue2rgb(p, q, h + 1.0/3.0),
            hue2rgb(p, q, h),
            hue2rgb(p, q, h - 1.0/3.0)
        );
    }

    // shadow/midtone/highlight/global: (hue 0...1, saturation 0...1,
    // luminance -1...1). blending: 0...1 overall strength. balance: -100...100.
    extern "C" float4 colorGrade(
        coreimage::sample_t s,
        float3 shadow, float3 midtone, float3 highlight, float3 global,
        float blending, float balance,
        coreimage::destination dest
    ) [[ stitchable ]] {
        float3 hsl = rgb2hsl(s.rgb);
        float luma = hsl.z;

        float t = clamp(luma - balance / 200.0, 0.0, 1.0);
        float shadowW = 1.0 - smoothstep(0.0, 0.5, t);
        float highlightW = smoothstep(0.5, 1.0, t);
        float midtoneW = max(0.0, 1.0 - shadowW - highlightW);

        float wShadow = shadowW * shadow.y;
        float wMidtone = midtoneW * midtone.y;
        float wHighlight = highlightW * highlight.y;
        float wGlobal = global.y;
        float totalWeight = wShadow + wMidtone + wHighlight + wGlobal;

        float lumShift = shadowW * shadow.z + midtoneW * midtone.z + highlightW * highlight.z + global.z;
        hsl.z = clamp(hsl.z + lumShift * 0.2 * blending, 0.0, 1.0);

        if (totalWeight > 0.0001) {
            float2 hueVec = float2(0.0);
            hueVec += float2(cos(shadow.x * 6.28318530718), sin(shadow.x * 6.28318530718)) * wShadow;
            hueVec += float2(cos(midtone.x * 6.28318530718), sin(midtone.x * 6.28318530718)) * wMidtone;
            hueVec += float2(cos(highlight.x * 6.28318530718), sin(highlight.x * 6.28318530718)) * wHighlight;
            hueVec += float2(cos(global.x * 6.28318530718), sin(global.x * 6.28318530718)) * wGlobal;

            if (length(hueVec) > 0.0001) {
                float targetHue = atan2(hueVec.y, hueVec.x) / 6.28318530718;
                if (targetHue < 0.0) targetHue += 1.0;
                float mixAmount = clamp(totalWeight, 0.0, 1.0) * blending;
                float diff = targetHue - hsl.x;
                diff -= floor(diff + 0.5);
                hsl.x = fract(hsl.x + diff * mixAmount + 1.0);
                hsl.y = clamp(hsl.y + mixAmount * 0.6, 0.0, 1.0);
            }
        }

        return float4(hsl2rgb(hsl), s.a);
    }
    """
}
