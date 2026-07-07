import Foundation
import SwiftData

/// A named, reusable snapshot of ``AdjustmentValues`` the user can apply to any
/// photo. Crop and rotation are intentionally excluded from presets (they are
/// composition, not look) and are left untouched when a preset is applied.
@Model
final class Preset {
    var id: UUID = UUID()
    var name: String = ""
    var createdDate: Date = Date()

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
    var toneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var redToneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var greenToneCurve: [Double] = AdjustmentValues.toneCurveIdentity
    var blueToneCurve: [Double] = AdjustmentValues.toneCurveIdentity
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

    init(name: String, values: AdjustmentValues) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.exposure = values.exposure
        self.contrast = values.contrast
        self.highlights = values.highlights
        self.shadows = values.shadows
        self.whites = values.whites
        self.blacks = values.blacks
        self.texture = values.texture
        self.clarity = values.clarity
        self.dehaze = values.dehaze
        self.temperature = values.temperature
        self.tint = values.tint
        self.vibrance = values.vibrance
        self.saturation = values.saturation
        self.isBlackAndWhite = values.isBlackAndWhite
        self.sharpness = values.sharpness
        self.noiseReduction = values.noiseReduction
        self.toneCurve = values.toneCurve
        self.redToneCurve = values.redToneCurve
        self.greenToneCurve = values.greenToneCurve
        self.blueToneCurve = values.blueToneCurve
        self.hslBands = values.hslBands
        self.redHue = values.redHue
        self.redSaturation = values.redSaturation
        self.greenHue = values.greenHue
        self.greenSaturation = values.greenSaturation
        self.blueHue = values.blueHue
        self.blueSaturation = values.blueSaturation
        self.colorGradeShadowHue = values.colorGradeShadowHue
        self.colorGradeShadowSaturation = values.colorGradeShadowSaturation
        self.colorGradeShadowLuminance = values.colorGradeShadowLuminance
        self.colorGradeMidtoneHue = values.colorGradeMidtoneHue
        self.colorGradeMidtoneSaturation = values.colorGradeMidtoneSaturation
        self.colorGradeMidtoneLuminance = values.colorGradeMidtoneLuminance
        self.colorGradeHighlightHue = values.colorGradeHighlightHue
        self.colorGradeHighlightSaturation = values.colorGradeHighlightSaturation
        self.colorGradeHighlightLuminance = values.colorGradeHighlightLuminance
        self.colorGradeGlobalHue = values.colorGradeGlobalHue
        self.colorGradeGlobalSaturation = values.colorGradeGlobalSaturation
        self.colorGradeGlobalLuminance = values.colorGradeGlobalLuminance
        self.colorGradeBlending = values.colorGradeBlending
        self.colorGradeBalance = values.colorGradeBalance
        self.lutFilename = values.lutFilename
        self.lutIntensity = values.lutIntensity
    }

    /// Merge this preset's look onto an existing edit, preserving that edit's
    /// crop/rotation/straighten.
    func applied(onto base: AdjustmentValues) -> AdjustmentValues {
        var v = base
        v.exposure = exposure
        v.contrast = contrast
        v.highlights = highlights
        v.shadows = shadows
        v.whites = whites
        v.blacks = blacks
        v.texture = texture
        v.clarity = clarity
        v.dehaze = dehaze
        v.temperature = temperature
        v.tint = tint
        v.vibrance = vibrance
        v.saturation = saturation
        v.isBlackAndWhite = isBlackAndWhite
        v.sharpness = sharpness
        v.noiseReduction = noiseReduction
        v.toneCurve = toneCurve
        v.redToneCurve = redToneCurve
        v.greenToneCurve = greenToneCurve
        v.blueToneCurve = blueToneCurve
        v.hslBands = hslBands
        v.redHue = redHue
        v.redSaturation = redSaturation
        v.greenHue = greenHue
        v.greenSaturation = greenSaturation
        v.blueHue = blueHue
        v.blueSaturation = blueSaturation
        v.colorGradeShadowHue = colorGradeShadowHue
        v.colorGradeShadowSaturation = colorGradeShadowSaturation
        v.colorGradeShadowLuminance = colorGradeShadowLuminance
        v.colorGradeMidtoneHue = colorGradeMidtoneHue
        v.colorGradeMidtoneSaturation = colorGradeMidtoneSaturation
        v.colorGradeMidtoneLuminance = colorGradeMidtoneLuminance
        v.colorGradeHighlightHue = colorGradeHighlightHue
        v.colorGradeHighlightSaturation = colorGradeHighlightSaturation
        v.colorGradeHighlightLuminance = colorGradeHighlightLuminance
        v.colorGradeGlobalHue = colorGradeGlobalHue
        v.colorGradeGlobalSaturation = colorGradeGlobalSaturation
        v.colorGradeGlobalLuminance = colorGradeGlobalLuminance
        v.colorGradeBlending = colorGradeBlending
        v.colorGradeBalance = colorGradeBalance
        v.lutFilename = lutFilename
        v.lutIntensity = lutIntensity
        return v
    }
}
