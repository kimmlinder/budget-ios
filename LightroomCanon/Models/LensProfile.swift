import Foundation

/// One (camera, lens) pair's distortion/vignetting calibration, ported from
/// the real [Lensfun](https://github.com/lensfun/lensfun) database — see
/// `scripts/lensfun/export_profiles.py` for how `Resources/LensProfiles.json`
/// (which this decodes) was generated, and `LensCorrectionKernel` for the
/// actual correction math applied with it.
///
/// Only used as a fallback for lenses `CIRAWFilter`'s own built-in correction
/// doesn't recognize — see `RAWProcessor.applyLensCorrection`.
struct LensProfile: Codable {
    struct DistortionPoint: Codable {
        let focal: Double
        let a: Double
        let b: Double
        let c: Double
    }
    struct VignettingPoint: Codable {
        let focal: Double
        let aperture: Double
        let distance: Double
        let k1: Double
        let k2: Double
        let k3: Double
    }

    let cameraModel: String
    let cameraCropFactor: Double
    let lensModel: String
    let aspectRatio: Double
    let distortion: [DistortionPoint]
    let vignetting: [VignettingPoint]
}

/// Loads and looks up `LensProfile`s from the bundled `LensProfiles.json`.
enum LensProfileDatabase {
    private static let profiles: [LensProfile] = {
        guard let url = Bundle.main.url(forResource: "LensProfiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [LensProfile]].self, from: data)
        else { return [] }
        return decoded["profiles"] ?? []
    }()

    /// Looks up a profile by EXIF camera/lens model strings. Both the
    /// database and real-world EXIF vary in spacing/hyphenation/maker
    /// prefixing for the same lens (e.g. EXIF `"EF-S55-250mm f/4-5.6 IS II"`
    /// vs. Lensfun's `"Canon EF-S 55-250mm f/4-5.6 IS II"`), so this
    /// compares a normalized (lowercased, whitespace/hyphen-stripped) form
    /// rather than requiring an exact match.
    static func profile(cameraModel: String?, lensModel: String?) -> LensProfile? {
        guard let cameraModel, let lensModel else { return nil }
        let normalizedCamera = normalize(cameraModel)
        let normalizedLens = normalize(lensModel)
        return profiles.first { p in
            let candidateCamera = normalize(p.cameraModel)
            let candidateLens = normalize(p.lensModel)
            let cameraMatches = candidateCamera == normalizedCamera
                || candidateCamera.hasSuffix(normalizedCamera) || normalizedCamera.hasSuffix(candidateCamera)
            let lensMatches = candidateLens.hasSuffix(normalizedLens) || normalizedLens.hasSuffix(candidateLens)
            return cameraMatches && lensMatches
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
