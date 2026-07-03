import CoreImage
import Metal

/// Shared, Metal-backed Core Image context for the whole app.
///
/// A single `CIContext` is expensive to create but cheap to reuse, and sharing
/// one keeps the GPU pipeline warm across thumbnail generation, live preview,
/// and export.
enum RenderEngine {
    /// The Metal device used for rendering, if the platform provides one.
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    static let context: CIContext = {
        if let device {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .name: "LightroomCanon"
            ])
        }
        // Fallback for the rare case with no Metal device (e.g. some simulators).
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// Working/output color space. sRGB keeps previews and exports consistent.
    static let colorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}
