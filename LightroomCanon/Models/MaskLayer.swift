import Foundation
import SwiftData

/// How a mask's region was produced — quick SAM-backed actions matching
/// Lightroom's "Select Subject"/"Select Sky"/"Select Background" masking
/// tools, or a manual tap (see `SAMSegmentationService`).
enum MaskKind: String, Codable {
    case subject, sky, background, custom
}

/// A local edit's tone/color/detail sliders — the masked-adjustment
/// equivalent of ``AdjustmentValues``, scoped to the subset Lightroom's own
/// masking panel exposes (no HSL/calibration/tone-curve/color-grading at the
/// mask level). Temperature/Tint are relative offsets here, not the absolute
/// Kelvin `AdjustmentValues.temperature` is — a mask has no RAW to read an
/// as-shot white balance from, and Lightroom's own local White Balance
/// sliders are relative shifts too.
struct LocalAdjustmentValues: Codable, Equatable, Sendable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0     // -100...100, relative shift
    var tint: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0

    static let neutral = LocalAdjustmentValues()
}

/// One local-adjustment mask attached to a ``Photo``: a saved region (as a
/// grayscale PNG on disk, see `MaskStorageService`) plus its own independent
/// set of ``LocalAdjustmentValues``, composited on top of the photo's global
/// edit — see `RAWProcessor.applyLocalMasks`. Multiple masks stack in
/// creation order, same as Lightroom's masking panel.
@Model
final class MaskLayer {
    var id: UUID = UUID()
    var kind: MaskKind = MaskKind.custom
    var name: String = ""
    /// Filename (not full path) of the grayscale mask PNG under
    /// `MaskStorageService.directory` — white where the local edit applies,
    /// black where it doesn't, soft-edged in between.
    var maskFilename: String = ""
    var isEnabled: Bool = true
    var createdDate: Date = Date()

    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0

    init(kind: MaskKind, name: String, maskFilename: String) {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.maskFilename = maskFilename
        self.createdDate = Date()
    }

    var values: LocalAdjustmentValues {
        get {
            LocalAdjustmentValues(
                exposure: exposure, contrast: contrast, highlights: highlights,
                shadows: shadows, whites: whites, blacks: blacks,
                temperature: temperature, tint: tint, saturation: saturation,
                clarity: clarity, sharpness: sharpness, noiseReduction: noiseReduction
            )
        }
        set {
            exposure = newValue.exposure; contrast = newValue.contrast
            highlights = newValue.highlights; shadows = newValue.shadows
            whites = newValue.whites; blacks = newValue.blacks
            temperature = newValue.temperature; tint = newValue.tint
            saturation = newValue.saturation; clarity = newValue.clarity
            sharpness = newValue.sharpness; noiseReduction = newValue.noiseReduction
        }
    }
}
