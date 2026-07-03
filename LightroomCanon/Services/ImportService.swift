import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// Handles bringing Canon RAW files into the catalog: building a persistent
/// bookmark to the original and extracting EXIF for display.
enum ImportService {

    /// Content types accepted by the file importer. Canon-specific UTIs first,
    /// with the generic camera-raw type and raw extensions as fallbacks so we
    /// still match files whose UTI isn't registered on the system.
    static var canonRAWTypes: [UTType] {
        var types: [UTType] = []
        for identifier in ["com.canon.cr3-raw-image", "com.canon.cr2-raw-image"] {
            if let t = UTType(identifier) { types.append(t) }
        }
        types.append(.rawImage) // public.camera-raw-image
        for ext in ["cr3", "cr2"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    /// Import a single user-selected file URL, returning the new (uninserted)
    /// `Photo`. The caller inserts it into the `ModelContext`.
    static func makePhoto(from url: URL) throws -> Photo {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        #if os(macOS)
        let creationOptions: URL.BookmarkCreationOptions = []
        #else
        let creationOptions: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let photo = Photo(filename: url.lastPathComponent, bookmark: bookmark)
        applyMetadata(from: url, to: photo)
        return photo
    }

    /// Read EXIF/TIFF metadata straight from the file without decoding pixels.
    static func applyMetadata(from url: URL, to photo: Photo) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

        photo.cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        photo.lensModel = exif?[kCGImagePropertyExifLensModel] as? String

        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
            photo.iso = isoArray.first
        }
        if let aperture = exif?[kCGImagePropertyExifFNumber] as? Double {
            photo.aperture = aperture
        }
        if let exposure = exif?[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            photo.shutterSpeed = exposure >= 1
                ? String(format: "%.0f\"", exposure)
                : "1/\(Int((1.0 / exposure).rounded()))"
        }
        if let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            photo.captureDate = exifDateFormatter.date(from: dateString)
        }
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
