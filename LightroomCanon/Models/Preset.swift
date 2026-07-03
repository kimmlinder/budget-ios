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
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0

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
        self.temperature = values.temperature
        self.tint = values.tint
        self.vibrance = values.vibrance
        self.saturation = values.saturation
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
        v.temperature = temperature
        v.tint = tint
        v.vibrance = vibrance
        v.saturation = saturation
        return v
    }
}
