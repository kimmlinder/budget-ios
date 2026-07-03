import CoreImage
import Foundation

/// Generates and caches grid thumbnails for imported photos.
///
/// Thumbnails are decoded with `CIRAWFilter` in draft mode at a reduced scale
/// (fast, low-memory) and written as JPEG into the app's Application Support
/// directory, keyed by the photo's id.
enum ThumbnailService {
    static let maxPixel: CGFloat = 512

    /// Directory where thumbnails live, created on first use.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Generate (or regenerate) a thumbnail from a resolved RAW URL. Returns the
    /// stored filename on success. Touches no SwiftData model, so it is safe to
    /// call off the main actor.
    @discardableResult
    static func generate(from sourceURL: URL, id: UUID) -> String? {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let rawFilter = CIRAWFilter(imageURL: sourceURL)
        rawFilter.isDraftModeEnabled = true

        guard let full = rawFilter.outputImage else { return nil }
        let scale = min(1, maxPixel / max(full.extent.width, full.extent.height))
        let thumb = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let filename = "\(id.uuidString).jpg"
        let destination = url(for: filename)
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = RenderEngine.context.jpegRepresentation(
            of: thumb,
            colorSpace: RenderEngine.colorSpace,
            options: [qualityKey: 0.8]
        ) else { return nil }

        do {
            try data.write(to: destination, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }
}
