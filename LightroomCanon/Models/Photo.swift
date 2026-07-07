import Foundation
import SwiftData

/// A catalog entry referencing a Canon RAW file on disk.
///
/// We never copy the (potentially very large) RAW into the app. Instead we
/// persist a security-scoped bookmark to the original and resolve it on demand
/// via ``resolveURL()``. Edits live in ``settings`` and are applied
/// non-destructively at render time.
@Model
final class Photo {
    var id: UUID = UUID()
    var filename: String = ""
    var importDate: Date = Date()

    /// Bookmark to the original RAW file (see `ImportService`).
    var bookmark: Data = Data()

    /// Filename (not full path) of the cached thumbnail under the app's
    /// thumbnail directory. `nil` until generated.
    var thumbnailFilename: String?

    /// Filename (not full path) of a cloud-straightened override image under
    /// `LightroomCloudService.overrideDirectory`, if the user has run Cloud
    /// Straighten on this photo. When set, the editor renders from this
    /// image instead of decoding the original RAW — see
    /// `EditorView.runCloudStraighten()` and `RAWProcessor.init(overrideImageURL:)`.
    var cloudStraightenedFilename: String?

    // Captured EXIF, shown in the info panel.
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var shutterSpeed: String?
    var aperture: Double?
    var captureDate: Date?

    /// Star rating, 0...5 — set from the Library grid, matching Lightroom's
    /// own quick-rating convention.
    var rating: Int = 0
    /// A quick "keep/reject candidate" marker, independent of rating —
    /// Lightroom's own flagging convention.
    var isFlagged: Bool = false

    @Relationship(deleteRule: .cascade)
    var settings: EditSettings?

    /// Local-adjustment masks (Subject/Sky/Background/custom selections),
    /// composited on top of the global edit — see `RAWProcessor.applyLocalMasks`.
    @Relationship(deleteRule: .cascade)
    var masks: [MaskLayer] = []

    /// User-defined groupings this photo belongs to — the inverse side of
    /// `PhotoCollection.photos`. A photo can be in any number of collections;
    /// removing a collection just un-groups its photos rather than deleting
    /// them (see `PhotoCollection`'s `.nullify` delete rule).
    var collections: [PhotoCollection] = []

    init(filename: String, bookmark: Data) {
        self.id = UUID()
        self.filename = filename
        self.bookmark = bookmark
        self.importDate = Date()
        self.settings = EditSettings()
    }

    /// Resolve the persisted bookmark back to a usable file URL.
    ///
    /// The returned URL may require security-scoped access — callers should
    /// wrap file reads in `startAccessingSecurityScopedResource()` /
    /// `stopAccessingSecurityScopedResource()`.
    func resolveURL() -> URL? {
        var isStale = false
        let options: URL.BookmarkResolutionOptions = []
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// The cloud-straightened override image on disk, if one has been generated.
    func resolveCloudStraightenedURL() -> URL? {
        guard let cloudStraightenedFilename else { return nil }
        return LightroomCloudService.overrideURL(for: cloudStraightenedFilename)
    }
}
