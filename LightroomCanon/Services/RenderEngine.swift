import CoreImage
import Metal

/// Metal-backed Core Image contexts for the app.
///
/// A `CIContext` is expensive to create but cheap to reuse, so each of the
/// two contexts below is a singleton shared by everything that needs that
/// kind of work — but they're deliberately two *separate* instances, not one:
/// `context` drives the interactive editor (the live `MTKView` preview, the
/// histogram, the one-time fast-preview bake, auto-crop measurement), all of
/// which are small/cheap and expect to run at interactive speed, while
/// `exportContext` is reserved for the one operation that's genuinely heavy —
/// rendering a full-resolution export — so a multi-second export render can't
/// contend with the live preview's own GPU work on the same context/command
/// queue and cause it to stutter.
enum RenderEngine {
    /// The Metal device used for rendering, if the platform provides one.
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    static let context: CIContext = makeContext(name: "LightroomCanon.preview")

    /// Used only by `ExportService` (and Cloud Straighten's full-quality
    /// upload render) — isolated from `context` so a full-resolution export
    /// never competes with the live preview for the same GPU queue.
    static let exportContext: CIContext = makeContext(name: "LightroomCanon.export")

    private static func makeContext(name: String) -> CIContext {
        if let device {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .name: name
            ])
        }
        // Fallback for the rare case with no Metal device (e.g. some simulators).
        return CIContext(options: [.cacheIntermediates: false, .name: name])
    }

    /// Working/output color space. sRGB keeps previews and exports consistent.
    static let colorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// An *extended-range* variant of `colorSpace` — same primaries/gamma,
    /// but values above 1.0 (genuine highlight headroom a RAW decode can
    /// carry) survive instead of being clamped. Standard `colorSpace` clamps
    /// to 0...1 the way a normal display-referred image is expected to, which
    /// is correct for anything final (export, the on-screen Metal drawable)
    /// but wrong for `RAWProcessor.fastPreview`'s bake — that bitmap is an
    /// *input* to further editing (Exposure, `HighlightRolloffKernel`), and
    /// clamping it there is what causes blown highlights to go flat instead
    /// of recoverable/compressible.
    static let extendedColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.extendedSRGB) ?? colorSpace
}
