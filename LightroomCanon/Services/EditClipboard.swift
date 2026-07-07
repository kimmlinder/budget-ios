import Observation

/// Holds one copied edit for "Copy Settings" / "Paste Settings", shared
/// between the library grid and the editor. Scoped to the current app
/// session only — deliberately not persisted.
@Observable
final class EditClipboard {
    static let shared = EditClipboard()
    private init() {}

    var copiedValues: AdjustmentValues?
}
