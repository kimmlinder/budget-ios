import CoreGraphics
import Foundation
import SwiftData

/// A plain, `Codable`/`Equatable` value type holding every adjustment.
///
/// This is deliberately decoupled from SwiftData so the rendering engine
/// (`RAWProcessor`) never depends on the persistence layer, and so presets and
/// live-editing state can be copied around cheaply.
///
/// Slider convention: tone/color adjustments use a Lightroom-style `-100...100`
/// range with `0` = no change, except `temperature`, which is an absolute
/// Kelvin value (2000...50000) with `0` reserved as a sentinel meaning "use
/// the camera's as-shot white balance" — see `RAWProcessor`. Crop is stored as
/// a normalized rectangle (`0...1`, origin top-left) and rotation as whole
/// degrees (0/90/180/270).
struct AdjustmentValues: Codable, Equatable, Sendable {
    // Light
    var exposure: Double = 0      // -100...100  -> roughly -5...+5 EV
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0

    // Presence
    var texture: Double = 0       // -100...100, fine detail (small-radius local contrast)
    var clarity: Double = 0       // -100...100, punch (large-radius local contrast)
    var dehaze: Double = 0        // -100...100; approximation (contrast/black-point/saturation), not a literal dark-channel-prior dehaze

    // Color
    var temperature: Double = 0   // Kelvin (2000...50000); 0 = as-shot
    var tint: Double = 0          // magenta (+) / green (-)
    var vibrance: Double = 0
    var saturation: Double = 0
    /// Desaturates to grayscale after all color/tone edits (including HSL),
    /// so HSL's per-band Luminance sliders double as a "B&W Mix" control.
    var isBlackAndWhite: Bool = false

    // Detail
    var sharpness: Double = 0     // 0...100
    var noiseReduction: Double = 0 // 0...100

    /// Per-band Hue/Saturation/Luminance, ordered per `HSLColorBand`
    /// (red, orange, yellow, green, aqua, blue, purple, magenta).
    var hslBands: [HSLBandValues] = Array(repeating: HSLBandValues(), count: 8)

    // Calibration — fine-tunes the RAW's primary Red/Green/Blue channels,
    // matching Lightroom's Camera Calibration panel. Hue cross-blends a
    // primary toward one neighboring channel; Saturation scales how much of
    // that primary's own signal survives versus flattening toward the
    // others. An approximation via `CIColorMatrix` (see
    // `RAWProcessor.applyCalibration`), not a reproduction of Adobe's actual
    // per-camera-profile color science.
    var redHue: Double = 0          // -100...100
    var redSaturation: Double = 0   // -100...100
    var greenHue: Double = 0
    var greenSaturation: Double = 0
    var blueHue: Double = 0
    var blueSaturation: Double = 0

    // Color Grading (formerly "Split Toning") — tints shadows, midtones,
    // and highlights independently, plus an overall Global tint, matching
    // Lightroom's current Color Grading panel. Hue is 0...360 (a color
    // wheel angle); Saturation 0...100; Luminance -100...100. `blending`
    // (0...100, Lightroom default 50) is an overall effect-strength
    // approximation, not a reproduction of Adobe's exact crossover-blending
    // math; `balance` (-100...100) shifts the shadow/highlight midpoint —
    // see `RAWProcessor.applyColorGrading`/`ColorGradingKernel`.
    var colorGradeShadowHue: Double = 0
    var colorGradeShadowSaturation: Double = 0
    var colorGradeShadowLuminance: Double = 0
    var colorGradeMidtoneHue: Double = 0
    var colorGradeMidtoneSaturation: Double = 0
    var colorGradeMidtoneLuminance: Double = 0
    var colorGradeHighlightHue: Double = 0
    var colorGradeHighlightSaturation: Double = 0
    var colorGradeHighlightLuminance: Double = 0
    var colorGradeGlobalHue: Double = 0
    var colorGradeGlobalSaturation: Double = 0
    var colorGradeGlobalLuminance: Double = 0
    var colorGradeBlending: Double = 50
    var colorGradeBalance: Double = 0

    // Look — a creative grade from an imported `.cube` 3D LUT (see
    // `LUTService`), applied via `CIColorCube` near the end of the pipeline.
    // `lutFilename` is a direct reference to the file on disk (like
    // `Photo.cloudStraightenedFilename`), not a `LUTPreset` id — the
    // rendering engine stays decoupled from SwiftData.
    var lutFilename: String?
    var lutIntensity: Double = 100  // 0...100

    // Lens
    var lensCorrectionEnabled: Bool = true

    // Tone curve: 5 fixed x-positions (0, .25, .5, .75, 1); y is user-adjustable
    // (0...1). Identity (y == x) means no change; applied after whites/blacks.
    var toneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    static let toneCurveIdentity: [Double] = [0, 0.25, 0.5, 0.75, 1]

    // Per-channel tone curves — same 5-point convention as `toneCurve`,
    // applied independently to each RGB channel (see
    // `RAWProcessor.applyChannelToneCurves`). Matches Lightroom's Tone Curve
    // panel, which has Red/Green/Blue curves alongside the master RGB one —
    // mainly used for split-toning-style color grading (e.g. lifting blacks
    // in the blue channel for a teal shadow tint).
    var redToneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var greenToneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var blueToneCurve: [Double] = AdjustmentValues.toneCurveIdentity

    // Geometry / Upright
    var straighten: Double = 0    // degrees, -45...45
    var rotation: Int = 0         // 0, 90, 180, 270
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1

    /// Which Upright tab is selected — a UI concern, see `GeometryMode`.
    var geometryMode: GeometryMode = .off
    /// Which correction filter to actually render — see `GeometryCorrectionKind`.
    var geometryCorrectionKind: GeometryCorrectionKind = .none
    /// The quad (topLeft, topRight, bottomRight, bottomLeft) that correction
    /// warps to a rectangle, normalized 0...1. Empty when kind is `.none`.
    var geometryCorners: [CGPoint] = []
    /// Guided mode's raw lines, kept so the user can see/adjust what they
    /// drew; `geometryCorners`/`geometryCorrectionKind` are derived from these.
    var guideLines: [GuideLine] = []
    /// Whether a successful Upright correction automatically trims the
    /// ragged, transparent corners it leaves behind — see `AutoCropService`.
    var autoCropEnabled: Bool = true
    /// Whether the current crop is the one `AutoCropService` computed for
    /// the active Upright correction (as opposed to one the user picked
    /// manually). An auto-set crop shouldn't outlive the correction that
    /// produced it — see `EditorView.resetCropIfAutoSet()`.
    var cropIsAutoSet: Bool = false

    /// The identity edit — renders the RAW at its baseline.
    static let neutral = AdjustmentValues()

    var isCropped: Bool {
        cropX != 0 || cropY != 0 || cropWidth != 1 || cropHeight != 1
    }
}

/// Per-photo, non-destructive edit state persisted alongside a ``Photo``.
///
/// Stored as flat properties (rather than a single blob) so SwiftUI can bind
/// individual sliders directly and SwiftData can diff them efficiently.
@Model
final class EditSettings {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0

    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0

    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var isBlackAndWhite: Bool = false

    var sharpness: Double = 0
    var noiseReduction: Double = 0
    var hslBands: [HSLBandValues] = Array(repeating: HSLBandValues(), count: 8)

    var redHue: Double = 0
    var redSaturation: Double = 0
    var greenHue: Double = 0
    var greenSaturation: Double = 0
    var blueHue: Double = 0
    var blueSaturation: Double = 0

    var colorGradeShadowHue: Double = 0
    var colorGradeShadowSaturation: Double = 0
    var colorGradeShadowLuminance: Double = 0
    var colorGradeMidtoneHue: Double = 0
    var colorGradeMidtoneSaturation: Double = 0
    var colorGradeMidtoneLuminance: Double = 0
    var colorGradeHighlightHue: Double = 0
    var colorGradeHighlightSaturation: Double = 0
    var colorGradeHighlightLuminance: Double = 0
    var colorGradeGlobalHue: Double = 0
    var colorGradeGlobalSaturation: Double = 0
    var colorGradeGlobalLuminance: Double = 0
    var colorGradeBlending: Double = 50
    var colorGradeBalance: Double = 0

    var lutFilename: String?
    var lutIntensity: Double = 100

    var lensCorrectionEnabled: Bool = true
    var toneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var redToneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var greenToneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var blueToneCurve: [Double] = AdjustmentValues.toneCurveIdentity

    var straighten: Double = 0
    var rotation: Int = 0
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1

    var geometryMode: GeometryMode = GeometryMode.off
    var geometryCorrectionKind: GeometryCorrectionKind = GeometryCorrectionKind.none
    var geometryCorners: [CGPoint] = []
    var guideLines: [GuideLine] = []
    var autoCropEnabled: Bool = true
    var cropIsAutoSet: Bool = false

    init() {}

    init(values: AdjustmentValues) {
        apply(values)
    }

    /// Bridge to the plain value type consumed by the rendering engine.
    var values: AdjustmentValues {
        get {
            AdjustmentValues(
                exposure: exposure, contrast: contrast, highlights: highlights,
                shadows: shadows, whites: whites, blacks: blacks,
                texture: texture, clarity: clarity, dehaze: dehaze,
                temperature: temperature, tint: tint, vibrance: vibrance,
                saturation: saturation, isBlackAndWhite: isBlackAndWhite,
                sharpness: sharpness, noiseReduction: noiseReduction,
                hslBands: hslBands,
                redHue: redHue, redSaturation: redSaturation,
                greenHue: greenHue, greenSaturation: greenSaturation,
                blueHue: blueHue, blueSaturation: blueSaturation,
                colorGradeShadowHue: colorGradeShadowHue,
                colorGradeShadowSaturation: colorGradeShadowSaturation,
                colorGradeShadowLuminance: colorGradeShadowLuminance,
                colorGradeMidtoneHue: colorGradeMidtoneHue,
                colorGradeMidtoneSaturation: colorGradeMidtoneSaturation,
                colorGradeMidtoneLuminance: colorGradeMidtoneLuminance,
                colorGradeHighlightHue: colorGradeHighlightHue,
                colorGradeHighlightSaturation: colorGradeHighlightSaturation,
                colorGradeHighlightLuminance: colorGradeHighlightLuminance,
                colorGradeGlobalHue: colorGradeGlobalHue,
                colorGradeGlobalSaturation: colorGradeGlobalSaturation,
                colorGradeGlobalLuminance: colorGradeGlobalLuminance,
                colorGradeBlending: colorGradeBlending, colorGradeBalance: colorGradeBalance,
                lutFilename: lutFilename, lutIntensity: lutIntensity,
                lensCorrectionEnabled: lensCorrectionEnabled, toneCurve: toneCurve,
                redToneCurve: redToneCurve, greenToneCurve: greenToneCurve, blueToneCurve: blueToneCurve,
                straighten: straighten, rotation: rotation,
                cropX: cropX, cropY: cropY, cropWidth: cropWidth, cropHeight: cropHeight,
                geometryMode: geometryMode, geometryCorrectionKind: geometryCorrectionKind,
                geometryCorners: geometryCorners, guideLines: guideLines,
                autoCropEnabled: autoCropEnabled, cropIsAutoSet: cropIsAutoSet
            )
        }
        set { apply(newValue) }
    }

    func apply(_ v: AdjustmentValues) {
        exposure = v.exposure; contrast = v.contrast; highlights = v.highlights
        shadows = v.shadows; whites = v.whites; blacks = v.blacks
        texture = v.texture; clarity = v.clarity; dehaze = v.dehaze
        temperature = v.temperature; tint = v.tint; vibrance = v.vibrance
        saturation = v.saturation; isBlackAndWhite = v.isBlackAndWhite
        sharpness = v.sharpness; noiseReduction = v.noiseReduction
        hslBands = v.hslBands
        redHue = v.redHue; redSaturation = v.redSaturation
        greenHue = v.greenHue; greenSaturation = v.greenSaturation
        blueHue = v.blueHue; blueSaturation = v.blueSaturation
        colorGradeShadowHue = v.colorGradeShadowHue
        colorGradeShadowSaturation = v.colorGradeShadowSaturation
        colorGradeShadowLuminance = v.colorGradeShadowLuminance
        colorGradeMidtoneHue = v.colorGradeMidtoneHue
        colorGradeMidtoneSaturation = v.colorGradeMidtoneSaturation
        colorGradeMidtoneLuminance = v.colorGradeMidtoneLuminance
        colorGradeHighlightHue = v.colorGradeHighlightHue
        colorGradeHighlightSaturation = v.colorGradeHighlightSaturation
        colorGradeHighlightLuminance = v.colorGradeHighlightLuminance
        colorGradeGlobalHue = v.colorGradeGlobalHue
        colorGradeGlobalSaturation = v.colorGradeGlobalSaturation
        colorGradeGlobalLuminance = v.colorGradeGlobalLuminance
        colorGradeBlending = v.colorGradeBlending; colorGradeBalance = v.colorGradeBalance
        lutFilename = v.lutFilename; lutIntensity = v.lutIntensity
        lensCorrectionEnabled = v.lensCorrectionEnabled; toneCurve = v.toneCurve
        redToneCurve = v.redToneCurve; greenToneCurve = v.greenToneCurve; blueToneCurve = v.blueToneCurve
        straighten = v.straighten; rotation = v.rotation
        cropX = v.cropX; cropY = v.cropY; cropWidth = v.cropWidth; cropHeight = v.cropHeight
        geometryMode = v.geometryMode; geometryCorrectionKind = v.geometryCorrectionKind
        geometryCorners = v.geometryCorners; guideLines = v.guideLines
        autoCropEnabled = v.autoCropEnabled; cropIsAutoSet = v.cropIsAutoSet
    }
}
