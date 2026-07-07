import CoreImage
import Foundation

/// Custom 8-band HSL (Hue/Saturation/Luminance) color adjustment.
///
/// Core Image has no built-in per-band HSL filter, so this compiles a small
/// stitchable Metal color kernel at first use (cached afterward). For a given
/// pixel's hue, the kernel finds the two nearest of the 8 evenly-spaced band
/// centers and linearly blends between their (hue, saturation, luminance)
/// offsets — a partition-of-unity by construction, so band-to-band
/// transitions are smooth with no double-counting or gaps.
enum HSLKernel {
    static let shared: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first as? CIColorKernel
    }()

    /// `bands` must have exactly 8 elements ordered per `HSLColorBand`.
    /// Returns `image` unchanged if every band is neutral or the kernel
    /// failed to compile (defensive — verified working at development time).
    static func apply(to image: CIImage, bands: [HSLBandValues]) -> CIImage {
        guard bands.count == 8, bands.contains(where: { !$0.isNeutral }), let kernel = shared
        else { return image }
        let args: [Any] = [image] + bands.map {
            CIVector(x: $0.hue / 100, y: $0.saturation / 100, z: $0.luminance / 100)
        }
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

    // Order matches HSLColorBand: red, orange, yellow, green, aqua, blue, purple, magenta.
    extern "C" float4 hslAdjust(
        coreimage::sample_t s,
        float3 red, float3 orange, float3 yellow, float3 green,
        float3 aqua, float3 blue, float3 purple, float3 magenta,
        coreimage::destination dest
    ) [[ stitchable ]] {
        float3 hsl = rgb2hsl(s.rgb);
        float hue = hsl.x;

        const int bandCount = 8;
        float3 bandParams[8] = { red, orange, yellow, green, aqua, blue, purple, magenta };

        float pos = hue * float(bandCount);
        int i0 = int(floor(pos)) % bandCount;
        if (i0 < 0) i0 += bandCount;
        int i1 = (i0 + 1) % bandCount;
        float t = pos - floor(pos);

        float3 blended = mix(bandParams[i0], bandParams[i1], t);

        float newHue = fract(hue + blended.x * (30.0 / 360.0));
        float newSat = clamp(hsl.y * (1.0 + blended.y), 0.0, 1.0);
        float newLum = clamp(hsl.z + blended.z * 0.5, 0.0, 1.0);

        float3 rgb = hsl2rgb(float3(newHue, newSat, newLum));
        return float4(rgb, s.a);
    }
    """
}
