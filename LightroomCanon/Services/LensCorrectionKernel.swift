import CoreImage
import Foundation

/// Distortion + vignetting correction ported from
/// [Lensfun](https://github.com/lensfun/lensfun)'s "ptlens" distortion model
/// and "pa" vignetting model — the exact math (including the polynomial
/// rescaling and normalized-coordinate-system conventions) is taken from
/// Lensfun's own `mod-coord.cpp`/`mod-color.cpp`/`modifier.cpp`, verified
/// against the real library (see `scripts/lensfun/`). Interpolation across
/// a lens's calibrated focal lengths is linear between the two nearest
/// points, not Lensfun's own cubic-spline/inverse-distance-weighting — close
/// enough for a photo whose focal length and aperture are already fixed at
/// capture time, and considerably simpler to maintain.
///
/// Used as a fallback only, when `RAWProcessor`'s `CIRAWFilter` has no
/// built-in profile for the shot's lens — see
/// `RAWProcessor.applyLensCorrection`.
enum LensCorrectionKernel {
    /// Precomputed, ready-to-apply correction for one specific photo (its
    /// pixel dimensions + the focal length/aperture it was shot at).
    struct Resolved {
        let normScale: Double
        let centerX: Double
        let centerY: Double
        /// Rescaled PTLens distortion terms (already incorporating the
        /// hugin-scaling/`d` adjustment — see `rescaledDistortion`).
        let a: Double
        let b: Double
        let c: Double
        /// Rescaled PA vignetting terms.
        let k1: Double
        let k2: Double
        let k3: Double
    }

    /// Resolves `profile` for a photo shot at `focalLength`mm/`aperture` f-number,
    /// at `imageWidth`x`imageHeight` pixels.
    static func resolve(
        _ profile: LensProfile, focalLength: Double, aperture: Double,
        imageWidth: Double, imageHeight: Double
    ) -> Resolved {
        let (a0, b0, c0) = interpolateDistortion(profile.distortion, focal: focalLength)
        let d = 1 - a0 - b0 - c0
        // Lensfun's own default when a calibration doesn't give an explicit
        // real-focal-length: nominal focal times the PTLens "d" term.
        let realFocal = d != 0 ? focalLength * d : focalLength

        let huginMillimetersDistortion =
            hypot(36.0, 24.0) / profile.cameraCropFactor / hypot(profile.aspectRatio, 1) / 2.0
        let huginScalingDistortion = realFocal / huginMillimetersDistortion
        let a = d != 0 ? a0 * pow(huginScalingDistortion, 3) / pow(d, 4) : 0
        let b = d != 0 ? b0 * pow(huginScalingDistortion, 2) / pow(d, 3) : 0
        let c = d != 0 ? c0 * huginScalingDistortion / pow(d, 2) : 0

        let (k1_0, k2_0, k3_0) = interpolateVignetting(profile.vignetting, focal: focalLength, aperture: aperture)
        let huginMillimetersVignetting = hypot(36.0, 24.0) / profile.cameraCropFactor / 2.0
        let huginScalingVignetting = realFocal / huginMillimetersVignetting
        let k1 = k1_0 * pow(huginScalingVignetting, 2)
        let k2 = k2_0 * pow(huginScalingVignetting, 4)
        let k3 = k3_0 * pow(huginScalingVignetting, 6)

        let normScale = hypot(36.0, 24.0) / profile.cameraCropFactor / hypot(imageWidth, imageHeight) / realFocal

        return Resolved(
            normScale: normScale, centerX: imageWidth / 2, centerY: imageHeight / 2,
            a: a, b: b, c: c, k1: k1, k2: k2, k3: k3
        )
    }

    /// Linearly interpolates (a, b, c) between the two calibration points
    /// bracketing `focal` — Lensfun itself uses a cubic spline across all
    /// points; see this file's doc comment for why this is linear instead.
    private static func interpolateDistortion(
        _ points: [LensProfile.DistortionPoint], focal: Double
    ) -> (Double, Double, Double) {
        guard !points.isEmpty else { return (0, 0, 0) }
        if focal <= points[0].focal { return (points[0].a, points[0].b, points[0].c) }
        if focal >= points[points.count - 1].focal {
            let p = points[points.count - 1]
            return (p.a, p.b, p.c)
        }
        for i in 0..<(points.count - 1) {
            let lo = points[i], hi = points[i + 1]
            guard focal >= lo.focal, focal <= hi.focal else { continue }
            let t = (focal - lo.focal) / (hi.focal - lo.focal)
            return (
                lo.a + (hi.a - lo.a) * t,
                lo.b + (hi.b - lo.b) * t,
                lo.c + (hi.c - lo.c) * t
            )
        }
        let p = points[0]
        return (p.a, p.b, p.c)
    }

    /// For each of the two focal-length groups bracketing `focal`, picks the
    /// calibration point (at `distance == 1000`, i.e. far-focus, matching
    /// most photos) whose aperture is closest to the shot's own — Lensfun
    /// interpolates aperture too (log-scale), but a shot's aperture is a
    /// single fixed value, so nearest-match is a reasonable simplification —
    /// then linearly interpolates between those two picks by focal length.
    private static func interpolateVignetting(
        _ points: [LensProfile.VignettingPoint], focal: Double, aperture: Double
    ) -> (Double, Double, Double) {
        let farFocus = points.filter { $0.distance >= 999 }
        let candidates = farFocus.isEmpty ? points : farFocus
        guard !candidates.isEmpty else { return (0, 0, 0) }

        let focalGroups = Dictionary(grouping: candidates, by: \.focal)
        let focals = focalGroups.keys.sorted()
        guard let firstFocal = focals.first, let lastFocal = focals.last else { return (0, 0, 0) }

        func closestByAperture(_ pts: [LensProfile.VignettingPoint]) -> LensProfile.VignettingPoint {
            pts.min(by: { abs($0.aperture - aperture) < abs($1.aperture - aperture) }) ?? pts[0]
        }

        if focal <= firstFocal {
            let p = closestByAperture(focalGroups[firstFocal] ?? [])
            return (p.k1, p.k2, p.k3)
        }
        if focal >= lastFocal {
            let p = closestByAperture(focalGroups[lastFocal] ?? [])
            return (p.k1, p.k2, p.k3)
        }
        for i in 0..<(focals.count - 1) {
            let loFocal = focals[i], hiFocal = focals[i + 1]
            guard focal >= loFocal, focal <= hiFocal else { continue }
            let lo = closestByAperture(focalGroups[loFocal] ?? [])
            let hi = closestByAperture(focalGroups[hiFocal] ?? [])
            let t = (focal - loFocal) / (hiFocal - loFocal)
            return (
                lo.k1 + (hi.k1 - lo.k1) * t,
                lo.k2 + (hi.k2 - lo.k2) * t,
                lo.k3 + (hi.k3 - lo.k3) * t
            )
        }
        let p = closestByAperture(focalGroups[firstFocal] ?? [])
        return (p.k1, p.k2, p.k3)
    }

    // MARK: - Core Image kernels

    static let distortionKernel: CIWarpKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first { $0 is CIWarpKernel } as? CIWarpKernel
    }()

    static let vignettingKernel: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first { $0 is CIColorKernel } as? CIColorKernel
    }()

    /// Applies distortion correction (a geometric warp — resamples `image`
    /// so the source pixel for each output pixel is looked up via the
    /// PTLens formula) followed by vignetting correction (a per-pixel
    /// multiplicative gain).
    static func apply(to image: CIImage, resolved: Resolved) -> CIImage {
        var result = image
        if let distortionKernel, resolved.a != 0 || resolved.b != 0 || resolved.c != 0 {
            result = distortionKernel.apply(
                extent: result.extent,
                roiCallback: { _, rect in rect },
                image: result,
                arguments: [
                    Float(resolved.normScale), Float(resolved.centerX), Float(resolved.centerY),
                    Float(resolved.a), Float(resolved.b), Float(resolved.c),
                ]
            ) ?? result
        }
        if let vignettingKernel, resolved.k1 != 0 || resolved.k2 != 0 || resolved.k3 != 0 {
            result = vignettingKernel.apply(
                extent: result.extent,
                arguments: [
                    result, Float(resolved.normScale), Float(resolved.centerX), Float(resolved.centerY),
                    Float(resolved.k1), Float(resolved.k2), Float(resolved.k3),
                ]
            ) ?? result
        }
        return result
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // PTLens distortion: for the *output* (corrected) pixel at `dest`,
    // computes which *source* (distorted, as-captured) pixel to sample —
    // Rd = Ru * (a*Ru^3 + b*Ru^2 + c*Ru + 1), in Lensfun's normalized,
    // image-center-origin coordinate system.
    extern "C" float2 lensDistortionWarp(
        float normScale, float centerX, float centerY, float a, float b, float c,
        coreimage::destination dest
    ) [[ stitchable ]] {
        float2 p = dest.coord();
        float nx = (p.x - centerX) * normScale;
        float ny = (p.y - centerY) * normScale;
        float r = sqrt(nx * nx + ny * ny);
        float poly3 = a * r * r * r + b * r * r + c * r + 1.0;
        float snx = nx * poly3;
        float sny = ny * poly3;
        return float2(snx / normScale + centerX, sny / normScale + centerY);
    }

    // PA de-vignetting: multiplicative gain = 1 / (1 + k1*r^2 + k2*r^4 + k3*r^6),
    // r in the same normalized coordinate system as the distortion warp above.
    extern "C" float4 lensVignettingGain(
        coreimage::sample_t s, float normScale, float centerX, float centerY,
        float k1, float k2, float k3, coreimage::destination dest
    ) [[ stitchable ]] {
        float2 p = dest.coord();
        float nx = (p.x - centerX) * normScale;
        float ny = (p.y - centerY) * normScale;
        float r2 = nx * nx + ny * ny;
        float r4 = r2 * r2;
        float r6 = r4 * r2;
        float c = 1.0 + k1 * r2 + k2 * r4 + k3 * r6;
        float gain = c > 0.0001 ? 1.0 / c : 1.0;
        return float4(s.rgb * gain, s.a);
    }
    """
}
