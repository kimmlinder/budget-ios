import Foundation
import SwiftData

/// A plain, `Codable`/`Equatable` value type holding every adjustment.
///
/// This is deliberately decoupled from SwiftData so the rendering engine
/// (`RAWProcessor`) never depends on the persistence layer, and so presets and
/// live-editing state can be copied around cheaply.
///
/// Slider convention: tone/color adjustments use a Lightroom-style `-100...100`
/// range with `0` = no change. Crop is stored as a normalized rectangle
/// (`0...1`, origin top-left) and rotation as whole degrees (0/90/180/270).
struct AdjustmentValues: Codable, Equatable, Sendable {
    // Light
    var exposure: Double = 0      // -100...100  -> roughly -5...+5 EV
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0

    // Color
    var temperature: Double = 0   // warm (+) / cool (-)
    var tint: Double = 0          // magenta (+) / green (-)
    var vibrance: Double = 0
    var saturation: Double = 0

    // Geometry
    var straighten: Double = 0    // degrees, -45...45
    var rotation: Int = 0         // 0, 90, 180, 270
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1

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

    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0

    var straighten: Double = 0
    var rotation: Int = 0
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1

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
                temperature: temperature, tint: tint, vibrance: vibrance,
                saturation: saturation, straighten: straighten, rotation: rotation,
                cropX: cropX, cropY: cropY, cropWidth: cropWidth, cropHeight: cropHeight
            )
        }
        set { apply(newValue) }
    }

    func apply(_ v: AdjustmentValues) {
        exposure = v.exposure; contrast = v.contrast; highlights = v.highlights
        shadows = v.shadows; whites = v.whites; blacks = v.blacks
        temperature = v.temperature; tint = v.tint; vibrance = v.vibrance
        saturation = v.saturation; straighten = v.straighten; rotation = v.rotation
        cropX = v.cropX; cropY = v.cropY; cropWidth = v.cropWidth; cropHeight = v.cropHeight
    }
}
