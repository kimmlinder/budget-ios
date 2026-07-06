import Foundation
import ZIPFoundation

/// Reads `.xmp` entries out of a `.zip` archive (e.g. a downloaded Lightroom
/// preset pack) directly into memory — no entry is ever written to disk as a
/// temporary file first.
///
/// This is deliberately just the archive-reading step. Turning each XMP
/// payload into a `Preset`/`AdjustmentValues` is a separate concern (XMP
/// parsing), not handled here.
enum ZIPXMPReader {
    struct XMPEntry {
        let filename: String
        let data: Data
    }

    enum ZIPError: LocalizedError {
        case cannotOpenArchive
        case noXMPEntries

        var errorDescription: String? {
            switch self {
            case .cannotOpenArchive: return "Couldn't open this as a .zip archive."
            case .noXMPEntries: return "This .zip doesn't contain any .xmp files."
            }
        }
    }

    /// Reads every `.xmp` entry from the archive at `url`, off the main
    /// actor — decompression is real CPU work, and a large preset pack can
    /// contain hundreds of entries.
    static func readXMPEntries(from url: URL) async throws -> [XMPEntry] {
        try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            guard let archive = Archive(url: url, accessMode: .read) else {
                throw ZIPError.cannotOpenArchive
            }

            var entries: [XMPEntry] = []
            for entry in archive where entry.type == .file && entry.path.lowercased().hasSuffix(".xmp") {
                var buffer = Data()
                _ = try archive.extract(entry) { chunk in
                    buffer.append(chunk)
                }
                let filename = (entry.path as NSString).lastPathComponent
                entries.append(XMPEntry(filename: filename, data: buffer))
            }

            guard !entries.isEmpty else { throw ZIPError.noXMPEntries }
            return entries
        }.value
    }
}
