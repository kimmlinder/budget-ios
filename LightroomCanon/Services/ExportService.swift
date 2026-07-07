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

    /// Render `values` applied to the RAW at `sourceURL` into encoded image
    /// data. Pass `isOverride: true` when `sourceURL` is a cloud-straightened
    /// override image (see `RAWProcessor.init(overrideImageURL:)`) rather
    /// than the original RAW — it lives in the app's own storage, so it
    /// needs no security-scoped access.
    static func render(
        sourceURL: URL, values: AdjustmentValues, options: Options, isOverride: Bool = false,
        masks: [RAWProcessor.ResolvedMask] = []
    ) throws -> Data {
        let accessed = isOverride ? false : sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let processor = isOverride
            ? RAWProcessor(overrideImageURL: sourceURL)
            : RAWProcessor(url: sourceURL)
        guard let processor, var image = processor.makeImage(values, masks: masks)
        else { throw ExportError.decodeFailed }

        if let maxDimension = options.maxDimension, maxDimension > 0 {
            let longest = max(image.extent.width, image.extent.height)
            if longest > maxDimension {
                let scale = CGFloat(maxDimension) / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let ciOptions: [CIImageRepresentationOption: Any] = [qualityKey: options.quality]

        // `exportContext` is a dedicated `CIContext`, isolated from the one
        // driving the live preview (`RenderEngine.context`) — this render is
        // full native RAW resolution and can take real time, and it runs on
        // a background task (see `ExportSheet.render()`), so it must not
        // contend with the interactive preview's own GPU work.
        let data: Data?
        switch options.format {
        case .jpeg:
            data = RenderEngine.exportContext.jpegRepresentation(
                of: image, colorSpace: RenderEngine.colorSpace, options: ciOptions)
        case .heic:
            data = RenderEngine.exportContext.heifRepresentation(
                of: image, format: .RGBA8, colorSpace: RenderEngine.colorSpace, options: ciOptions)
        }

        guard let data else { throw ExportError.encodeFailed }
        return data
    }
}
