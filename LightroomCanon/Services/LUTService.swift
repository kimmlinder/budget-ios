import Foundation

/// Parses Adobe/Iridas `.cube` 3D LUT files and manages the app's imported
/// LUT library on disk.
///
/// `.cube` is an open, industry-standard text format (DaVinci Resolve,
/// Premiere, RawTherapee, and most film-emulation LUT packs all read/write
/// it) — unlike Adobe's proprietary DCP camera-profile format, there's
/// nothing to reverse-engineer here, just a documented text layout.
enum LUTService {
    struct ParsedLUT {
        let dimension: Int
        /// RGBA Float32 data, ordered red-fastest/green/blue-slowest — the
        /// same order both `.cube` files and `CIColorCube`'s `cubeData` use,
        /// so parsing needs no reordering, just an alpha channel appended.
        let data: Data
    }

    enum LUTError: LocalizedError {
        case invalidFormat
        case unsupportedShaper

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "This doesn't look like a valid .cube LUT file."
            case .unsupportedShaper: return "This LUT combines a 1D shaper with the 3D cube, which isn't supported."
            }
        }
    }

    /// Directory where imported `.cube` files live, created on first use.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Copies a user-picked `.cube` file into the app's own LUT library,
    /// validating that it parses first so a broken file never gets imported.
    /// Returns the stored filename.
    static func importLUT(from sourceURL: URL) throws -> String {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        _ = try parse(text) // validate before copying

        let filename = "\(UUID().uuidString).cube"
        try text.write(to: url(for: filename), atomically: true, encoding: .utf8)
        return filename
    }

    /// In-memory cache of parsed LUT data, keyed by filename — a LUT with a
    /// meaningful size (33³ ≈ 36,000 data lines) is too expensive to
    /// re-parse from text on every slider tick, so this is read once per
    /// session per LUT.
    private static var cache: [String: ParsedLUT] = [:]

    static func parsedLUT(filename: String) -> ParsedLUT? {
        if let cached = cache[filename] { return cached }
        guard let text = try? String(contentsOf: url(for: filename), encoding: .utf8),
              let parsed = try? parse(text)
        else { return nil }
        cache[filename] = parsed
        return parsed
    }

    static func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
        cache[filename] = nil
    }

    /// Parses the Adobe/Iridas `.cube` text format: an optional `TITLE`,
    /// `LUT_3D_SIZE N`, optional `DOMAIN_MIN`/`DOMAIN_MAX` (assumed to be the
    /// default 0...1 if present — a non-default domain isn't remapped, a
    /// known limitation since virtually every distributed `.cube` LUT uses
    /// the default), then N³ lines of `R G B` floats ordered with red
    /// varying fastest, then green, then blue.
    static func parse(_ text: String) throws -> ParsedLUT {
        var dimension: Int?
        var triplets: [(Float, Float, Float)] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("LUT_1D_SIZE") {
                throw LUTError.unsupportedShaper
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, let size = Int(parts[1]) else { throw LUTError.invalidFormat }
                dimension = size
                continue
            }
            if line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                continue
            }

            let components = line.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
            guard components.count == 3 else { continue }
            triplets.append((components[0], components[1], components[2]))
        }

        guard let dimension, dimension > 1 else { throw LUTError.invalidFormat }
        guard triplets.count == dimension * dimension * dimension else { throw LUTError.invalidFormat }

        var floats = [Float]()
        floats.reserveCapacity(triplets.count * 4)
        for t in triplets {
            floats.append(t.0)
            floats.append(t.1)
            floats.append(t.2)
            floats.append(1.0)
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return ParsedLUT(dimension: dimension, data: data)
    }
}
