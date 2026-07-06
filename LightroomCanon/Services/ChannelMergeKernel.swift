import CoreImage
import Foundation

/// Recombines three independently-processed, single-channel-isolated images
/// (see `RAWProcessor.isolateChannel`) back into one RGBA image, taking red
/// from the first, green from the second, blue from the third.
///
/// Used by `RAWProcessor.applyChannelToneCurves`: `CIToneCurve` always
/// applies one curve identically to all three channels, so an independently
/// *shaped* curve per channel means running the curve on each channel in
/// isolation and merging the results back together here.
enum ChannelMergeKernel {
    static let shared: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: metalSource) else { return nil }
        return kernels.first as? CIColorKernel
    }()

    /// `red`/`green`/`blue` must each be a same-extent, grayscale (R == G ==
    /// B) image already holding that channel's processed value.
    static func apply(red: CIImage, green: CIImage, blue: CIImage) -> CIImage {
        guard let kernel = shared else { return red }
        return kernel.apply(extent: red.extent, arguments: [red, green, blue]) ?? red
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" float4 channelMerge(
        coreimage::sample_t red, coreimage::sample_t green, coreimage::sample_t blue,
        coreimage::destination dest
    ) [[ stitchable ]] {
        return float4(red.r, green.r, blue.r, red.a);
    }
    """
}
