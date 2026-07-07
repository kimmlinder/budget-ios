import Foundation

/// One of the 8 hue bands in the HSL panel, in Lightroom's usual order.
/// `HSLKernel` expects exactly these 8, in this order.
enum HSLColorBand: Int, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }
}

/// Hue/Saturation/Luminance offsets for one color band, Lightroom-style
/// `-100...100` with `0` = no change.
struct HSLBandValues: Codable, Equatable, Sendable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}
