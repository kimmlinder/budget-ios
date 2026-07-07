import Foundation
import SwiftData

/// A named, reusable reference to an imported `.cube` LUT file (see
/// `LUTService`), so the "Look" panel can show a human name and the same
/// imported LUT can be applied across many photos without duplicating it.
///
/// Deliberately separate from `AdjustmentValues.lutFilename`: the rendering
/// engine only ever needs the filename (like `Photo.cloudStraightenedFilename`),
/// never a SwiftData lookup — this model exists purely for the library UI.
@Model
final class LUTPreset {
    var id: UUID = UUID()
    var name: String = ""
    var filename: String = ""
    var createdDate: Date = Date()

    init(name: String, filename: String) {
        self.id = UUID()
        self.name = name
        self.filename = filename
        self.createdDate = Date()
    }
}
