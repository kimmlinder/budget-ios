import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Builds the Core Image pipeline that turns a Canon RAW file plus a set of
/// ``AdjustmentValues`` into a rendered image.
///
/// The heavy lifting — demosaicing the Canon CR2/CR3 sensor data, applying the
/// as-shot white balance, and baseline tone mapping — is done by Apple's
/// `CIRAWFilter`, which supports Canon RAW natively. We then chain a small set
/// of standard `CIFilter`s for the user-facing sliders. Everything is lazy:
/// `outputImage` describes a graph that only executes when a `CIContext`
/// renders it.
final class RAWProcessor {
    let url: URL

    /// One RAW filter instance is kept alive for the open photo. Adjusting a
    /// slider just mutates its properties instead of re-decoding the file.
    private let rawFilter: CIRAWFilter

    /// As-shot white balance captured at load time, used as the zero point for
    /// the temperature/tint sliders.
    private let baseTemperature: Float
    private let baseTint: Float

    init(url: URL) {
        self.url = url
        let filter = CIRAWFilter(imageURL: url)
        self.rawFilter = filter
        self.baseTemperature = filter.neutralTemperature
        self.baseTint = filter.neutralTint
    }

    /// Whether the RAW decoded successfully.
    var isValid: Bool { rawFilter.outputImage != nil }

    /// The native pixel size of the RAW, if known.
    var nativeExtent: CGRect? { rawFilter.outputImage?.extent }

    /// Produce the fully-adjusted `CIImage` for the given edit.
    func makeImage(_ v: AdjustmentValues) -> CIImage? {
        // --- Stage 1: RAW-level adjustments (exposure + white balance) ---
        rawFilter.exposure = Float(v.exposure / 20.0)                 // ±100 -> ±5 EV
        rawFilter.neutralTemperature = baseTemperature + Float(v.temperature * 30.0)
        rawFilter.neutralTint = baseTint + Float(v.tint * 1.5)

        guard var image = rawFilter.outputImage else { return nil }

        // --- Stage 2: tone & color via standard filters ---
        image = applyColorControls(image, contrast: v.contrast, saturation: v.saturation)
        image = applyHighlightShadow(image, highlights: v.highlights, shadows: v.shadows)
        image = applyWhitesBlacks(image, whites: v.whites, blacks: v.blacks)
        image = applyVibrance(image, amount: v.vibrance)

        // --- Stage 3: geometry (straighten -> crop -> rotate) ---
        image = applyStraighten(image, degrees: v.straighten)
        image = applyCrop(image, v)
        image = applyRotation(image, degrees: v.rotation)

        return image
    }

    // MARK: - Filter stages

    private func applyColorControls(_ image: CIImage, contrast: Double, saturation: Double) -> CIImage {
        guard contrast != 0 || saturation != 0 else { return image }
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.contrast = Float(1.0 + contrast / 200.0)     // ±100 -> 0.5...1.5
        f.saturation = Float(1.0 + saturation / 100.0) // ±100 -> 0...2
        f.brightness = 0
        return f.outputImage ?? image
    }

    private func applyHighlightShadow(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        guard highlights != 0 || shadows != 0 else { return image }
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage = image
        f.radius = 5
        // highlightAmount < 1 recovers highlights; only negative values act here.
        f.highlightAmount = Float(1.0 + min(0, highlights) / 100.0)
        // shadowAmount in -1...1; positive opens up shadows.
        f.shadowAmount = Float(shadows / 100.0)
        return f.outputImage ?? image
    }

    private func applyWhitesBlacks(_ image: CIImage, whites: Double, blacks: Double) -> CIImage {
        guard whites != 0 || blacks != 0 else { return image }
        let w = whites / 100.0
        let b = blacks / 100.0
        let f = CIFilter.toneCurve()
        f.inputImage = image

        // Black point: positive lifts output, negative crushes input.
        let p0: CGPoint = b >= 0
            ? CGPoint(x: 0, y: 0.2 * b)
            : CGPoint(x: 0.2 * -b, y: 0)
        // White point: positive pushes input, negative pulls output.
        let p4: CGPoint = w >= 0
            ? CGPoint(x: 1 - 0.2 * w, y: 1)
            : CGPoint(x: 1, y: 1 + 0.2 * w)

        f.point0 = p0
        f.point1 = CGPoint(x: 0.25, y: 0.25)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: 0.75)
        f.point4 = p4
        return f.outputImage ?? image
    }

    private func applyVibrance(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        let f = CIFilter.vibrance()
        f.inputImage = image
        f.amount = Float(amount / 100.0)   // ±1
        return f.outputImage ?? image
    }

    private func applyStraighten(_ image: CIImage, degrees: Double) -> CIImage {
        guard degrees != 0 else { return image }
        let f = CIFilter.straightenFilter()
        f.inputImage = image
        f.angle = Float(degrees * .pi / 180.0)
        return f.outputImage ?? image
    }

    private func applyCrop(_ image: CIImage, _ v: AdjustmentValues) -> CIImage {
        guard v.isCropped else { return image }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        // cropY is measured from the top; Core Image's origin is bottom-left.
        let rect = CGRect(
            x: e.origin.x + v.cropX * e.width,
            y: e.origin.y + (1 - v.cropY - v.cropHeight) * e.height,
            width: v.cropWidth * e.width,
            height: v.cropHeight * e.height
        )
        return image.cropped(to: rect)
    }

    private func applyRotation(_ image: CIImage, degrees: Int) -> CIImage {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized != 0 else { return image }
        let radians = -CGFloat(normalized) * .pi / 180.0
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        // Re-anchor to a non-negative origin so downstream extent math is simple.
        return rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                                  y: -rotated.extent.origin.y))
    }
}
