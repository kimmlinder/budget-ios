import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Renders a photo's current edit to a shareable image file.
enum ExportService {

    enum Format: String, CaseIterable, Identifiable {
        case jpeg = "JPEG"
        case heic = "HEIC"
        var id: String { rawValue }

        var utType: UTType { self == .jpeg ? .jpeg : .heic }
        var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    }

    struct Options {
        var format: Format = .jpeg
        var quality: Double = 0.9          // 0...1
        /// Longest-edge cap in pixels; `nil` = full resolution.
        var maxDimension: Double? = nil
    }

    enum ExportError: Error { case decodeFailed, encodeFailed }

    /// Render `values` applied to the RAW at `sourceURL` into encoded image data.
    static func render(sourceURL: URL, values: AdjustmentValues, options: Options) throws -> Data {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let processor = RAWProcessor(url: sourceURL)
        guard var image = processor.makeImage(values) else { throw ExportError.decodeFailed }

        if let maxDimension, maxDimension > 0 {
            let longest = max(image.extent.width, image.extent.height)
            if longest > maxDimension {
                let scale = CGFloat(maxDimension) / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let ciOptions: [CIImageRepresentationOption: Any] = [qualityKey: options.quality]

        let data: Data?
        switch options.format {
        case .jpeg:
            data = RenderEngine.context.jpegRepresentation(
                of: image, colorSpace: RenderEngine.colorSpace, options: ciOptions)
        case .heic:
            data = RenderEngine.context.heifRepresentation(
                of: image, format: .RGBA8, colorSpace: RenderEngine.colorSpace, options: ciOptions)
        }

        guard let data else { throw ExportError.encodeFailed }
        return data
    }
}
