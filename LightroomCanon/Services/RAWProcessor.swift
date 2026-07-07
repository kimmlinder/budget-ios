import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Builds the Core Image pipeline that turns a Canon RAW file plus a set of
/// ``AdjustmentValues`` into a rendered image.
///
/// The heavy lifting — demosaicing the Canon CR2/CR3 sensor data, applying the
/// as-shot white balance, and baseline tone mapping — is done by Apple's
/// `CIRAWFilter`, which supports Canon RAW natively. We then chain a small set
/// of standard `CIFilter`s for the user-facing sliders. Everything is lazy:
/// `outputImage` describes a graph that only executes when a `CIContext`
/// renders it.
final class RAWProcessor {
    let url: URL

    /// A live RAW filter, kept only for the two paths that need every native
    /// pixel and true RAW-stage exposure/white-balance: Export and Cloud
    /// Straighten's upload. `nil` for interactive editing, which instead
    /// renders from `overrideImage` — see `fastPreview(url:maxDimension:lensCorrectionEnabled:)`.
    private let rawFilter: CIRAWFilter?

    /// A pre-materialized (not lazy) bitmap this processor renders from
    /// instead of a live RAW decode — either the interactive editor's
    /// screen-resolution "fast preview" bake, or a cloud-straightened result
    /// loaded from disk. Whichever it is, `CIRAWFilter`'s demosaic never runs
    /// again for the lifetime of this instance: only the generic stage-2/3
    /// filters below re-run per slider change, which is what keeps dragging a
    /// slider fast regardless of the source RAW's native resolution.
    private let overrideImage: CIImage?

    /// As-shot white balance, used both as the zero point for the
    /// Temperature/Tint sliders and as the "current" white point the generic
    /// `applyWhiteBalance` fallback shifts away from in override mode.
    /// Captured from the real RAW at bake time when available; a reasonable
    /// fixed default (5500K / 0 tint) for a cloud-straightened image, which
    /// has no RAW to read it from.
    private let baseTemperature: Float
    private let baseTint: Float

    /// 35mm-equivalent focal length from EXIF, used by the Keystone
    /// Correction filters to model perspective realistically. Falls back to a
    /// reasonable "normal" lens value when the file doesn't report one.
    private let focalLength35mm: Float

    /// A `LensProfile` fallback for when `CIRAWFilter` itself has no
    /// built-in correction for this lens (see `lensCorrectionSupported`),
    /// plus the actual (not 35mm-equivalent) focal length and f-number
    /// needed to resolve it against a specific render's pixel size — see
    /// `applyLensCorrectionFallback`. Read directly from EXIF (mirroring
    /// `focalLength35mm`, decoupled from `Photo`/SwiftData); `nil` when no
    /// matching profile is bundled or any EXIF piece is missing.
    private let lensProfile: LensProfile?
    private let lensFocalLength: Float?
    private let lensAperture: Float?

    /// Full-quality, on-demand RAW decoding — every render re-runs
    /// `CIRAWFilter`'s demosaic at native resolution. Only for Export and
    /// Cloud Straighten's upload; the interactive editor uses
    /// `fastPreview(url:maxDimension:lensCorrectionEnabled:)` instead.
    init?(url: URL) {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        self.url = url
        self.rawFilter = filter
        self.overrideImage = nil
        self.baseTemperature = filter.neutralTemperature
        self.baseTint = filter.neutralTint
        self.focalLength35mm = Self.readFocalLength35mm(from: url) ?? 35
        (self.lensProfile, self.lensFocalLength, self.lensAperture) = Self.readLensProfile(from: url)
    }

    /// Renders from a pre-corrected image on disk (e.g. the result of
    /// `LightroomCloudService.straighten`) instead of decoding a RAW.
    convenience init?(overrideImageURL url: URL) {
        guard let image = CIImage(contentsOf: url) else { return nil }
        self.init(overrideImage: image, metadataURL: url, baseTemperature: 5500, baseTint: 0)
    }

    private init(overrideImage: CIImage, metadataURL: URL, baseTemperature: Float, baseTint: Float) {
        self.url = metadataURL
        self.rawFilter = nil
        self.overrideImage = overrideImage
        self.baseTemperature = baseTemperature
        self.baseTint = baseTint
        self.focalLength35mm = Self.readFocalLength35mm(from: metadataURL) ?? 35
        (self.lensProfile, self.lensFocalLength, self.lensAperture) = Self.readLensProfile(from: metadataURL)
    }

    /// Decodes `url` once, at a fraction of its native resolution, and
    /// materializes the result into a plain bitmap — the interactive
    /// editor's "fast preview": the on-screen preview never shows more than
    /// screen resolution anyway (`MetalImageView` aspect-fits into the
    /// drawable), so there's no benefit to re-running a multi-megapixel
    /// demosaic on every slider tick. Draft mode also skips the full
    /// demosaic/noise-reduction pass, which is the single biggest cost
    /// `CIRAWFilter` has. Exposure and white balance become generic
    /// approximations afterward (`applyExposure`/`applyWhiteBalance`) since
    /// there's no live RAW filter left to carry them; lens correction is
    /// baked in at whatever `lensCorrectionEnabled` was at load time and
    /// can't be toggled live in this mode (see `lensCorrectionSupported`).
    /// Export and Cloud Straighten each decode fresh at full quality instead
    /// (`init(url:)`), so neither of those tradeoffs affects their output.
    static func fastPreview(url: URL, maxDimension: CGFloat, lensCorrectionEnabled: Bool) -> RAWProcessor? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.isDraftModeEnabled = true
        if let (w, h) = readPixelSize(from: url), max(w, h) > 0 {
            filter.scaleFactor = Float(min(1, maxDimension / max(w, h)))
        }
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = lensCorrectionEnabled
        }
        let baseTemperature = filter.neutralTemperature
        let baseTint = filter.neutralTint
        guard let decoded = filter.outputImage,
              // Pin format/color space explicitly — the no-argument overload
              // doesn't reliably preserve the RAW pipeline's own working
              // space, and unlike every other render in this file, this
              // bitmap becomes an *input* to the rest of the filter chain
              // (exposure, HSL, tone curve) rather than a final display
              // output. A silently mismatched space here is exactly what
              // produces dirty/blown highlights and orange-shifting skin
              // tones once Exposure or the tone filters run on top of it.
              //
              // `.RGBAh` (16-bit float) + the *extended*-range color space
              // keeps any real highlight headroom the RAW decode carries
              // above nominal white — an 8-bit, standard-range bake would
              // clip that data away right here, before the user has even
              // touched Exposure, leaving nothing for
              // `HighlightRolloffKernel` (or pulling Exposure down) to
              // recover.
              let cgImage = RenderEngine.context.createCGImage(
                decoded, from: decoded.extent, format: .RGBAh, colorSpace: RenderEngine.extendedColorSpace)
        else { return nil }
        return RAWProcessor(
            overrideImage: CIImage(cgImage: cgImage), metadataURL: url,
            baseTemperature: baseTemperature, baseTint: baseTint)
    }

    private static func readFocalLength35mm(from url: URL) -> Float? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let value = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber
        else { return nil }
        return value.floatValue
    }

    /// Looks up a bundled `LensProfile` fallback (see `LensProfileDatabase`)
    /// for this file's actual camera/lens, plus the actual (not
    /// 35mm-equivalent) focal length and f-number needed to resolve it —
    /// `nil` wherever any of camera/lens/focal/aperture is missing, or no
    /// matching profile is bundled.
    private static func readLensProfile(from url: URL) -> (LensProfile?, Float?, Float?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (nil, nil, nil) }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        let lensModel = exif?[kCGImagePropertyExifLensModel] as? String
        let focal = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.floatValue
        let aperture = (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.floatValue
        guard let focal, let aperture,
              let profile = LensProfileDatabase.profile(cameraModel: cameraModel, lensModel: lensModel)
        else { return (nil, focal, aperture) }
        return (profile, focal, aperture)
    }

    /// The RAW's native pixel dimensions from its embedded metadata — cheap
    /// to read (no demosaic needed), used to size `scaleFactor` for `.preview`
    /// quality without first paying for a full-resolution decode.
    private static func readPixelSize(from url: URL) -> (width: CGFloat, height: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        return (CGFloat(width), CGFloat(height))
    }

    /// Whether the source decoded successfully.
    var isValid: Bool { rawFilter?.outputImage != nil || overrideImage != nil }

    /// The native pixel size of the source, if known.
    var nativeExtent: CGRect? { rawFilter?.outputImage?.extent ?? overrideImage?.extent }

    /// The camera's as-shot white balance, in Kelvin — the Temperature
    /// slider's true zero point for this photo. Not meaningful in override
    /// mode (see `overrideImage`).
    var nativeTemperature: Double { Double(baseTemperature) }

    /// Whether this source has lens-profile data (distortion/vignette/CA)
    /// Core Image can correct. Canon embeds this for its own lenses;
    /// third-party lenses on a Canon body often don't have a profile. Always
    /// `false` in override mode — there's no RAW to carry a lens profile.
    var lensCorrectionSupported: Bool { rawFilter?.isLensCorrectionSupported ?? false }

    /// Whether `LensCorrectionKernel` can step in with a bundled
    /// Lensfun-derived profile (see `LensProfileDatabase`) for lenses
    /// `CIRAWFilter` itself has no correction for — this is what actually
    /// drives the Lens Corrections toggle being enabled when
    /// `lensCorrectionSupported` is `false`.
    var lensCorrectionFallbackAvailable: Bool { !lensCorrectionSupported && lensProfile != nil }

    /// Applies `LensCorrectionKernel`'s distortion + vignetting correction
    /// using the bundled fallback profile, resolved against `image`'s own
    /// pixel size (which can be the full native RAW or the fast-preview's
    /// downscaled bake — the correction math itself is resolution-independent
    /// via `LensCorrectionKernel.Resolved`'s normalized coordinate system).
    /// A no-op whenever `lensCorrectionSupported` is `true` (Apple's own
    /// correction already ran as part of `rawFilter.outputImage`) or no
    /// fallback profile/EXIF data is available.
    private func applyLensCorrectionFallback(_ image: CIImage, enabled: Bool) -> CIImage {
        guard enabled, !lensCorrectionSupported,
              let lensProfile, let lensFocalLength, let lensAperture
        else { return image }
        let resolved = LensCorrectionKernel.resolve(
            lensProfile, focalLength: Double(lensFocalLength), aperture: Double(lensAperture),
            imageWidth: image.extent.width, imageHeight: image.extent.height
        )
        return LensCorrectionKernel.apply(to: image, resolved: resolved)
    }

    /// Produce the fully-adjusted `CIImage` for the given edit, optionally
    /// compositing local-adjustment masks (Subject/Sky/Background/custom —
    /// see `MaskLayer`/`SAMSegmentationService`) on top of the global edit.
    func makeImage(_ v: AdjustmentValues, masks: [ResolvedMask] = []) -> CIImage? {
        var image: CIImage
        if let rawFilter {
            // --- Stage 1: RAW-level adjustments (exposure + white balance) ---
            rawFilter.exposure = Float(v.exposure / 20.0)              // ±100 -> ±5 EV
            // `temperature` is an absolute Kelvin value; 0 is a sentinel
            // meaning "use the camera's as-shot white balance"
            // (AdjustmentValues.neutral and a freshly-reset edit both land here).
            rawFilter.neutralTemperature = v.temperature > 0 ? Float(v.temperature) : baseTemperature
            rawFilter.neutralTint = baseTint + Float(v.tint * 1.5)
            if rawFilter.isLensCorrectionSupported {
                rawFilter.isLensCorrectionEnabled = v.lensCorrectionEnabled
            }
            guard let output = rawFilter.outputImage else { return nil }
            image = output
        } else if let overrideImage {
            // No RAW exposure/white-balance stage available on an
            // already-rendered bitmap, so approximate both generically.
            // Apple's own lens correction has no such equivalent and is
            // simply frozen at whatever it was when this bitmap was baked
            // (see `fastPreview`) — but `applyLensCorrectionFallback` below
            // still re-runs live every call, same as everything else here.
            image = applyExposure(overrideImage, ev: v.exposure / 20.0)
            image = applyWhiteBalance(image, temperature: v.temperature, tint: v.tint)
        } else {
            return nil
        }
        image = applyLensCorrectionFallback(image, enabled: v.lensCorrectionEnabled)

        // Soft highlight shoulder, right after exposure/white-balance and
        // before anything else touches the image — see
        // `HighlightRolloffKernel` for why this needs to run this early
        // (it needs genuine headroom above nominal white to compress, which
        // later 0...1-clamped stages won't have) and why it scales channels
        // uniformly instead of per-channel.
        image = HighlightRolloffKernel.apply(to: image)

        // "Look" — an imported 3D LUT — runs right after the highlight
        // shoulder brings the image back to a well-behaved ~0...1 range: a
        // color cube is defined over a fixed 0...1 grid, so it needs to run
        // *after* the roll-off (not before, alongside Exposure) or
        // extended-range highlight headroom would fall outside the cube's
        // domain and get clamped unpredictably. This still keeps it acting
        // like a camera-profile step — everything downstream (Calibration,
        // Basic, HSL, tone curve) is graded on top of it — rather than a
        // final creative pass layered over already-finished color work.
        image = applyLUT(image, v: v)

        // --- Stage 2: tone & color via standard filters ---
        // Calibration goes first — it fine-tunes the primaries everything
        // else (contrast, HSL, tone curve) is built on top of, matching
        // Lightroom's Camera Calibration panel conceptually underlying the
        // rest of the Basic/Color panels rather than layering after them.
        image = applyCalibration(image, v: v)
        image = applyColorControls(image, contrast: v.contrast, saturation: v.saturation)
        image = applyHighlightShadow(image, highlights: v.highlights, shadows: v.shadows)
        image = applyWhitesBlacks(image, whites: v.whites, blacks: v.blacks)
        image = applyPresence(image, texture: v.texture, clarity: v.clarity)
        image = applyDehaze(image, amount: v.dehaze)
        image = applyToneCurve(image, points: v.toneCurve)
        image = applyChannelToneCurves(
            image, red: v.redToneCurve, green: v.greenToneCurve, blue: v.blueToneCurve)
        image = applyVibrance(image, amount: v.vibrance)
        image = HSLKernel.apply(to: image, bands: v.hslBands)
        image = applyColorGrading(image, v: v)
        image = applyBlackAndWhite(image, enabled: v.isBlackAndWhite)
        image = applyDetail(image, noiseReduction: v.noiseReduction, sharpness: v.sharpness)
        image = applyLocalMasks(image, masks: masks)

        // --- Stage 3: geometry (straighten -> upright -> crop -> rotate) ---
        image = applyStraighten(image, degrees: v.straighten)
        image = applyGeometryCorrection(image, kind: v.geometryCorrectionKind, corners: v.geometryCorners)
        image = applyCrop(image, v)
        image = applyRotation(image, degrees: v.rotation)

        return image
    }

    // MARK: - Filter stages

    /// Generic exposure fallback for override-mode images (no `CIRAWFilter`
    /// exposure stage available there — see `makeImage`).
    private func applyExposure(_ image: CIImage, ev: Double) -> CIImage {
        guard ev != 0 else { return image }
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = Float(ev)
        return f.outputImage ?? image
    }

    /// Generic white-balance fallback for override-mode images, via Core
    /// Image's chromatic-adaptation filter rather than `CIRAWFilter`'s
    /// native (and unavailable here) neutralTemperature/neutralTint.
    private func applyWhiteBalance(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature > 0 || tint != 0 else { return image }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = image
        f.neutral = CIVector(x: CGFloat(baseTemperature), y: CGFloat(baseTint))
        f.targetNeutral = CIVector(
            x: temperature > 0 ? CGFloat(temperature) : CGFloat(baseTemperature),
            y: CGFloat(baseTint) + CGFloat(tint * 1.5)
        )
        return f.outputImage ?? image
    }

    /// Camera Calibration's Red/Green/Blue primary Hue and Saturation, via
    /// `CIColorMatrix` — a linear approximation, not a reproduction of
    /// Adobe's actual per-camera-profile color science (which Core Image
    /// doesn't expose). Each primary's Hue cross-blends its output row
    /// toward one neighboring channel (matching Lightroom's hue-shift
    /// direction for that primary); Saturation scales the whole row so the
    /// channel's own signal reads purer (>0) or flatter (<0).
    private func applyCalibration(_ image: CIImage, v: AdjustmentValues) -> CIImage {
        guard v.redHue != 0 || v.redSaturation != 0 || v.greenHue != 0
            || v.greenSaturation != 0 || v.blueHue != 0 || v.blueSaturation != 0
        else { return image }

        // Hue shift is capped well short of a full ±100% cross-blend —
        // Lightroom's Calibration hue sliders nudge a primary, they don't
        // swap it for a neighbor.
        let maxMix = 0.35
        let rMix = v.redHue / 100 * maxMix      // + toward green, - toward blue
        let gMix = v.greenHue / 100 * maxMix    // + toward blue, - toward red
        let bMix = v.blueHue / 100 * maxMix     // + toward red, - toward green
        let rSat = 1 + v.redSaturation / 100
        let gSat = 1 + v.greenSaturation / 100
        let bSat = 1 + v.blueSaturation / 100

        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: (1 - abs(rMix)) * rSat, y: max(0, rMix) * rSat,
                              z: max(0, -rMix) * rSat, w: 0)
        f.gVector = CIVector(x: max(0, -gMix) * gSat, y: (1 - abs(gMix)) * gSat,
                              z: max(0, gMix) * gSat, w: 0)
        f.bVector = CIVector(x: max(0, bMix) * bSat, y: max(0, -bMix) * bSat,
                              z: (1 - abs(bMix)) * bSat, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// One resolved local-adjustment mask ready to composite — a loaded
    /// grayscale `CIImage` (see `MaskStorageService`/`SAMSegmentationService`)
    /// paired with the `LocalAdjustmentValues` it carries. Resolving happens
    /// in `EditorView` (SwiftData/disk I/O doesn't belong in this class).
    struct ResolvedMask {
        let maskImage: CIImage
        let values: LocalAdjustmentValues
    }

    /// Composites each mask's independently-adjusted image on top of the
    /// fully globally-graded result, in stacking order — matching
    /// Lightroom's masking panel, where later masks paint over earlier ones.
    /// Mask images are resized to match the working image's extent since
    /// they're typically captured at the interactive preview's resolution,
    /// not whatever this particular render pass is producing (preview vs.
    /// full-quality export) — smooth upscaling is the right tradeoff since a
    /// SAM mask is already a soft, feathered selection, not a precision
    /// pixel-accurate cutout.
    private func applyLocalMasks(_ image: CIImage, masks: [ResolvedMask]) -> CIImage {
        guard !masks.isEmpty else { return image }
        var result = image
        for mask in masks {
            let adjusted = applyLocalAdjustment(result, mask.values)
            let maskExtent = mask.maskImage.extent
            guard maskExtent.width > 0, maskExtent.height > 0 else { continue }
            let scale = CGAffineTransform(
                scaleX: result.extent.width / maskExtent.width,
                y: result.extent.height / maskExtent.height)
            let scaledMask = mask.maskImage.transformed(by: scale)

            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = result
            blend.maskImage = scaledMask
            result = blend.outputImage?.cropped(to: result.extent) ?? result
        }
        return result
    }

    /// The masked-adjustment equivalent of the global Basic/Color/Detail
    /// panels, reusing the same filter stages — see `LocalAdjustmentValues`
    /// for why this is a bounded subset (no HSL/calibration/tone curve at
    /// the mask level, matching Lightroom's own masking panel).
    private func applyLocalAdjustment(_ image: CIImage, _ v: LocalAdjustmentValues) -> CIImage {
        var result = image
        result = applyExposure(result, ev: v.exposure / 20.0)
        result = applyLocalWhiteBalance(result, temperature: v.temperature, tint: v.tint)
        result = applyColorControls(result, contrast: v.contrast, saturation: v.saturation)
        result = applyHighlightShadow(result, highlights: v.highlights, shadows: v.shadows)
        result = applyWhitesBlacks(result, whites: v.whites, blacks: v.blacks)
        result = applyPresence(result, texture: 0, clarity: v.clarity)
        result = applyDetail(result, noiseReduction: v.noiseReduction, sharpness: v.sharpness)
        return result
    }

    /// Unlike the global Temperature slider (an absolute Kelvin value read
    /// against the RAW's as-shot white balance), a mask has no as-shot
    /// reference to shift from — `LocalAdjustmentValues.temperature`/`tint`
    /// are relative pushes around a fixed nominal daylight neutral (6500K),
    /// same `tint * 1.5` scale as `applyWhiteBalance`'s fallback path.
    private func applyLocalWhiteBalance(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature != 0 || tint != 0 else { return image }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = image
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: 6500 + temperature * 20, y: tint * 1.5)
        return f.outputImage ?? image
    }

    /// Applies the selected "Look" — an imported `.cube` 3D LUT (see
    /// `LUTService`) — via `CIColorCube`, dissolved against the un-graded
    /// image by `lutIntensity` since `CIColorCube` itself has no notion of a
    /// partial application.
    private func applyLUT(_ image: CIImage, v: AdjustmentValues) -> CIImage {
        guard let filename = v.lutFilename, v.lutIntensity > 0,
              let lut = LUTService.parsedLUT(filename: filename)
        else { return image }

        let f = CIFilter.colorCube()
        f.inputImage = image
        f.cubeDimension = Float(lut.dimension)
        f.cubeData = lut.data
        guard let graded = f.outputImage else { return image }
        guard v.lutIntensity < 100 else { return graded }

        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = graded
        dissolve.time = Float(v.lutIntensity / 100)
        return dissolve.outputImage ?? graded
    }

    /// Contrast and Saturation are deliberately two separate filter passes,
    /// not one `CIColorControls` call handling both — see
    /// `LuminanceContrastKernel` for why running contrast through
    /// `CIColorControls` directly entangles it with saturation.
    private func applyColorControls(_ image: CIImage, contrast: Double, saturation: Double) -> CIImage {
        var result = image
        if contrast != 0 {
            result = LuminanceContrastKernel.apply(to: result, contrast: Float(1.0 + contrast / 200.0))
        }
        if saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = result
            f.saturation = Float(1.0 + saturation / 100.0) // ±100 -> 0...2
            f.contrast = 1
            f.brightness = 0
            result = f.outputImage ?? result
        }
        return result
    }

    private func applyHighlightShadow(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        guard highlights != 0 || shadows != 0 else { return image }
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage = image
        f.radius = 5
        // highlightAmount < 1 recovers highlights; only negative values act here.
        f.highlightAmount = Float(1.0 + min(0, highlights) / 100.0)
        // shadowAmount in -1...1; positive opens up shadows.
        f.shadowAmount = Float(shadows / 100.0)
        return f.outputImage ?? image
    }

    private func applyWhitesBlacks(_ image: CIImage, whites: Double, blacks: Double) -> CIImage {
        guard whites != 0 || blacks != 0 else { return image }
        let w = whites / 100.0
        let b = blacks / 100.0
        let f = CIFilter.toneCurve()
        f.inputImage = image

        // Black point: positive lifts output, negative crushes input.
        let p0: CGPoint = b >= 0
            ? CGPoint(x: 0, y: 0.2 * b)
            : CGPoint(x: 0.2 * -b, y: 0)
        // White point: positive pushes input, negative pulls output.
        let p4: CGPoint = w >= 0
            ? CGPoint(x: 1 - 0.2 * w, y: 1)
            : CGPoint(x: 1, y: 1 + 0.2 * w)

        f.point0 = p0
        f.point1 = CGPoint(x: 0.25, y: 0.25)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: 0.75)
        f.point4 = p4
        return f.outputImage ?? image
    }

    /// Texture (fine detail) and Clarity (punch) via `CIUnsharpMask` at two
    /// spatial scales — a small radius for Texture, a larger and softer one
    /// for Clarity, each scaled to the image's own size so the effect is
    /// resolution-independent. `CIUnsharpMask`'s intensity doesn't go
    /// negative (verified empirically — it's a no-op below 0), so negative
    /// values instead dissolve toward a same-radius Gaussian blur for
    /// genuine softening.
    ///
    /// Both `maxIntensity` values are intentionally modest, and
    /// `LuminanceBlendKernel` tapers the whole effect toward zero at the
    /// tonal extremes — Lightroom's own Clarity/Texture read as a gentle
    /// midtone "punch", not a sharpening filter, and running an unsharp mask
    /// at full strength across the whole tonal range is what made this feel
    /// harsh/overdone by comparison.
    private func applyPresence(_ image: CIImage, texture: Double, clarity: Double) -> CIImage {
        var result = image
        result = applyLocalContrast(result, amount: texture, radiusFraction: 0.004, maxIntensity: 0.4)
        result = applyLocalContrast(result, amount: clarity, radiusFraction: 0.05, maxIntensity: 0.6)
        return result
    }

    /// Runs the unsharp-mask/blur entirely on a luminance-only copy of
    /// `image`, then recombines with the original via `LuminanceBlendKernel`
    /// — see its doc comment for why processing R/G/B independently (what a
    /// bare `CIUnsharpMask` on the color image would do) isn't how
    /// Lightroom's Texture/Clarity behave.
    private func applyLocalContrast(
        _ image: CIImage, amount: Double, radiusFraction: Double, maxIntensity: Double
    ) -> CIImage {
        guard amount != 0 else { return image }
        let radius = Float(max(image.extent.width, image.extent.height)) * Float(radiusFraction)
        guard radius > 0 else { return image }

        let luma = luminanceOnly(image)
        let processedLuma: CIImage

        if amount > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = luma
            f.radius = radius
            f.intensity = Float(amount / 100.0) * Float(maxIntensity)
            processedLuma = f.outputImage ?? luma
        } else {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = luma.clampedToExtent()
            blur.radius = radius
            guard let blurred = blur.outputImage?.cropped(to: image.extent) else { return image }
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = luma
            dissolve.targetImage = blurred
            dissolve.time = Float(min(1, -amount / 100.0))
            processedLuma = dissolve.outputImage ?? luma
        }

        return LuminanceBlendKernel.apply(original: image, enhancedLuma: processedLuma)
    }

    /// A luminance-only (R == G == B, matching `LuminanceBlendKernel`'s
    /// expectations) copy of `image`, using the same Rec. 709 luma weights
    /// as `LuminanceContrastKernel`/`HighlightRolloffKernel`.
    private func luminanceOnly(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        let lumaVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        f.rVector = lumaVector
        f.gVector = lumaVector
        f.bVector = lumaVector
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// An approximation, not a literal dark-channel-prior dehaze: positive
    /// values add local contrast, crush the black point, and nudge
    /// saturation up — the combination that reads as "cutting through haze"
    /// even though it isn't modeling atmospheric scattering directly.
    /// Negative values do the reverse for a soft, hazy look.
    private func applyDehaze(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        let t = amount / 100.0  // -1...1

        let cc = CIFilter.colorControls()
        cc.inputImage = image
        cc.contrast = Float(1.0 + t * 0.15)
        cc.saturation = Float(1.0 + t * 0.1)
        guard let contrasted = cc.outputImage else { return image }

        let f = CIFilter.toneCurve()
        f.inputImage = contrasted
        f.point0 = CGPoint(x: max(0, 0.05 * t), y: max(0, -0.05 * t))
        f.point1 = CGPoint(x: 0.25, y: 0.25 - 0.03 * t)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: 0.75 + 0.03 * t)
        f.point4 = CGPoint(x: min(1, 1 - 0.05 * -t), y: min(1, 1 + 0.05 * -t))
        return f.outputImage ?? image
    }

    /// Color Grading (formerly Split Toning) — see `ColorGradingKernel`.
    /// Placed after HSL and before Black & White, matching HSL's own
    /// placement: both still have a visible effect (via their Luminance
    /// components) right up until color is discarded.
    private func applyColorGrading(_ image: CIImage, v: AdjustmentValues) -> CIImage {
        let hasEffect = v.colorGradeShadowSaturation != 0 || v.colorGradeMidtoneSaturation != 0
            || v.colorGradeHighlightSaturation != 0 || v.colorGradeGlobalSaturation != 0
            || v.colorGradeShadowLuminance != 0 || v.colorGradeMidtoneLuminance != 0
            || v.colorGradeHighlightLuminance != 0 || v.colorGradeGlobalLuminance != 0
        guard hasEffect else { return image }

        return ColorGradingKernel.apply(
            to: image,
            shadow: .init(hue: v.colorGradeShadowHue, saturation: v.colorGradeShadowSaturation,
                          luminance: v.colorGradeShadowLuminance),
            midtone: .init(hue: v.colorGradeMidtoneHue, saturation: v.colorGradeMidtoneSaturation,
                            luminance: v.colorGradeMidtoneLuminance),
            highlight: .init(hue: v.colorGradeHighlightHue, saturation: v.colorGradeHighlightSaturation,
                              luminance: v.colorGradeHighlightLuminance),
            global: .init(hue: v.colorGradeGlobalHue, saturation: v.colorGradeGlobalSaturation,
                           luminance: v.colorGradeGlobalLuminance),
            blending: v.colorGradeBlending, balance: v.colorGradeBalance
        )
    }

    /// Desaturates to grayscale. Placed after HSL so its per-band Luminance
    /// sliders still shape tonal separation before color is discarded — a
    /// stand-in for Lightroom's dedicated B&W Mix panel.
    private func applyBlackAndWhite(_ image: CIImage, enabled: Bool) -> CIImage {
        guard enabled else { return image }
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = 0
        return f.outputImage ?? image
    }

    /// User-drawn tone curve, applied on top of the whites/blacks adjustment
    /// (matching Lightroom's Basic panel + Tone Curve panel order).
    private func applyToneCurve(_ image: CIImage, points: [Double]) -> CIImage {
        guard points.count == 5, points != AdjustmentValues.toneCurveIdentity else { return image }
        let xs = AdjustmentValues.toneCurveIdentity
        let f = CIFilter.toneCurve()
        f.inputImage = image
        f.point0 = CGPoint(x: xs[0], y: points[0])
        f.point1 = CGPoint(x: xs[1], y: points[1])
        f.point2 = CGPoint(x: xs[2], y: points[2])
        f.point3 = CGPoint(x: xs[3], y: points[3])
        f.point4 = CGPoint(x: xs[4], y: points[4])
        return f.outputImage ?? image
    }

    /// Per-channel (Red/Green/Blue) tone curves — Lightroom's Tone Curve
    /// panel has these alongside the master RGB curve above, mainly used for
    /// split-toning-style color grading (e.g. lifting blacks in the blue
    /// channel for a teal shadow tint). `CIToneCurve` always applies one
    /// curve identically to all three channels, so an independently *shaped*
    /// curve per channel means: isolate each channel into its own grayscale
    /// image, reuse `applyToneCurve` on each in isolation, then recombine via
    /// `ChannelMergeKernel`.
    private func applyChannelToneCurves(
        _ image: CIImage, red: [Double], green: [Double], blue: [Double]
    ) -> CIImage {
        let identity = AdjustmentValues.toneCurveIdentity
        guard red.count == 5, green.count == 5, blue.count == 5,
              red != identity || green != identity || blue != identity
        else { return image }

        let redChannel = applyToneCurve(isolateChannel(image, channel: 0), points: red)
        let greenChannel = applyToneCurve(isolateChannel(image, channel: 1), points: green)
        let blueChannel = applyToneCurve(isolateChannel(image, channel: 2), points: blue)
        return ChannelMergeKernel.apply(red: redChannel, green: greenChannel, blue: blueChannel)
    }

    /// A grayscale (R == G == B) copy of `image` holding just the value of
    /// channel `channel` (0 = red, 1 = green, 2 = blue) — the isolated input
    /// `applyChannelToneCurves` runs each per-channel curve against.
    private func isolateChannel(_ image: CIImage, channel: Int) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        let vector: CIVector
        switch channel {
        case 0: vector = CIVector(x: 1, y: 0, z: 0, w: 0)
        case 1: vector = CIVector(x: 0, y: 1, z: 0, w: 0)
        default: vector = CIVector(x: 0, y: 0, z: 1, w: 0)
        }
        f.rVector = vector
        f.gVector = vector
        f.bVector = vector
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    private func applyVibrance(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        let f = CIFilter.vibrance()
        f.inputImage = image
        f.amount = Float(amount / 100.0)   // ±1
        return f.outputImage ?? image
    }

    /// Denoise before sharpening — sharpening a noisy image just amplifies
    /// the noise, so the reduction pass always runs first.
    private func applyDetail(_ image: CIImage, noiseReduction: Double, sharpness: Double) -> CIImage {
        guard noiseReduction != 0 || sharpness != 0 else { return image }
        var result = image
        if noiseReduction != 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = result
            f.noiseLevel = Float(noiseReduction / 100.0 * 0.1)  // 0...100 -> 0...0.1
            f.sharpness = 0.4                                   // CI's own default
            result = f.outputImage ?? result
        }
        if sharpness != 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = result
            f.sharpness = Float(sharpness / 100.0 * 2.0)        // 0...100 -> 0...2
            result = f.outputImage ?? result
        }
        return result
    }

    private func applyStraighten(_ image: CIImage, degrees: Double) -> CIImage {
        guard degrees != 0 else { return image }
        let f = CIFilter.straighten()
        f.inputImage = image
        f.angle = Float(degrees * .pi / 180.0)
        return f.outputImage ?? image
    }

    /// Upright/perspective correction. `corners` are normalized (0...1,
    /// bottom-left origin, matching Core Image's coordinate space) and are
    /// warped to a rectangle by the Keystone Correction filter matching
    /// `kind` — Vertical/Horizontal/Combined guides, set either by a one-shot
    /// Vision detector (Auto/Vertical/Full) or by the user's own Guided lines.
    private func applyGeometryCorrection(
        _ image: CIImage, kind: GeometryCorrectionKind, corners: [CGPoint]
    ) -> CIImage {
        guard kind != .none, corners.count == 4 else { return image }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let pts = corners.map {
            CGPoint(x: e.origin.x + $0.x * e.width, y: e.origin.y + $0.y * e.height)
        }
        let (topLeft, topRight, bottomRight, bottomLeft) = (pts[0], pts[1], pts[2], pts[3])

        switch kind {
        case .none:
            return image
        case .vertical:
            let f = CIFilter.keystoneCorrectionVertical()
            f.inputImage = image
            f.topLeft = topLeft; f.topRight = topRight
            f.bottomLeft = bottomLeft; f.bottomRight = bottomRight
            f.focalLength = focalLength35mm
            return f.outputImage ?? image
        case .horizontal:
            let f = CIFilter.keystoneCorrectionHorizontal()
            f.inputImage = image
            f.topLeft = topLeft; f.topRight = topRight
            f.bottomLeft = bottomLeft; f.bottomRight = bottomRight
            f.focalLength = focalLength35mm
            return f.outputImage ?? image
        case .combined:
            let f = CIFilter.keystoneCorrectionCombined()
            f.inputImage = image
            f.topLeft = topLeft; f.topRight = topRight
            f.bottomLeft = bottomLeft; f.bottomRight = bottomRight
            f.focalLength = focalLength35mm
            return f.outputImage ?? image
        }
    }

    private func applyCrop(_ image: CIImage, _ v: AdjustmentValues) -> CIImage {
        guard v.isCropped else { return image }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        // cropY is measured from the top; Core Image's origin is bottom-left.
        let rect = CGRect(
            x: e.origin.x + v.cropX * e.width,
            y: e.origin.y + (1 - v.cropY - v.cropHeight) * e.height,
            width: v.cropWidth * e.width,
            height: v.cropHeight * e.height
        )
        return image.cropped(to: rect)
    }

    private func applyRotation(_ image: CIImage, degrees: Int) -> CIImage {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized != 0 else { return image }
        let radians = -CGFloat(normalized) * .pi / 180.0
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        // Re-anchor to a non-negative origin so downstream extent math is simple.
        return rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                                  y: -rotated.extent.origin.y))
    }
}
