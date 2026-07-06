import CoreGraphics
import Foundation

/// Which Upright tab is selected in the editor. Purely a UI concern — it
/// decides what controls are shown and which detector runs when the user taps
/// the mode, but rendering only ever looks at `GeometryCorrectionKind` below.
enum GeometryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, auto, level, vertical, full, guided
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .level: return "Level"
        case .vertical: return "Vertical"
        case .full: return "Full"
        case .guided: return "Guided"
        }
    }
}

/// Which `CIFilter` `RAWProcessor` should run for the current geometry
/// correction. Decoupled from `GeometryMode` because Guided mode picks the
/// filter based on which guide lines the user actually drew (2 vertical, 2
/// horizontal, or both), not on the mode tab itself.
enum GeometryCorrectionKind: String, Codable, Sendable {
    case none, vertical, horizontal, combined
}

/// A user-drawn guide line for Guided mode, in normalized image coordinates
/// (0...1, bottom-left origin — matching Core Image / Vision's convention).
/// Two lines of the same orientation become one correction; a vertical pair
/// and a horizontal pair together become a combined correction.
///
/// `id` gives each line a stable identity independent of its position in the
/// array, so SwiftUI can diff a `ForEach` over `[GuideLine]` safely across
/// deletions — identifying rows by array index instead (`indices, id: \.self`)
/// is a known crash: a still-transitioning row can hold a captured index that
/// no longer exists once the array shrinks.
struct GuideLine: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var start: CGPoint
    var end: CGPoint

    /// A line is "vertical" if it's more up-down than left-right.
    var isVertical: Bool { abs(end.y - start.y) >= abs(end.x - start.x) }
}
