import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates and caches grid thumbnails for imported photos.
///
/// Reads the RAW's embedded, already-rendered JPEG preview via ImageIO
/// instead of decoding the sensor data — every Canon CR2/CR3 carries one
/// specifically so browsers don't have to demosaic just to show a thumbnail.
/// This is what keeps importing a folder of 100+ RAWs fast and low-memory:
/// `CIRAWFilter`, even in draft mode, still has to hold a decoded image per
/// file, and running that many decodes at once (one per imported photo,
/// since each import kicks off its own background task) is a real
/// out-of-memory risk that this sidesteps entirely.
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

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return nil }

        // `.IfAbsent` prefers the RAW's embedded preview and only falls back
        // to decoding the full image if a file happens to have none — using
        // `.Always` here would defeat the entire point by forcing a full
        // decode every time.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let filename = "\(id.uuidString).jpg"
        let destination = url(for: filename)
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return filename
    }
}
