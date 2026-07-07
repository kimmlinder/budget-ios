import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Persists mask layer bitmaps to disk, keyed by a generated filename —
/// mirrors `ThumbnailService`/`LightroomCloudService.overrideDirectory`.
/// `MaskLayer` itself only stores the filename, keeping SwiftData rows small;
/// the actual grayscale pixels live here as a PNG.
enum MaskStorageService {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Masks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Renders `mask` (any working color space — only luminance is read back
    /// by `RAWProcessor`) to an 8-bit grayscale PNG and returns the stored
    /// filename, or `nil` on failure.
    @discardableResult
    static func save(_ mask: CIImage) -> String? {
        let filename = "\(UUID().uuidString).png"
        guard let cgImage = RenderEngine.context.createCGImage(
            mask, from: mask.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()
        ) else { return nil }
        guard let destination = CGImageDestinationCreateWithURL(
            url(for: filename) as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return filename
    }

    static func load(_ filename: String) -> CIImage? {
        CIImage(contentsOf: url(for: filename))
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }
}
