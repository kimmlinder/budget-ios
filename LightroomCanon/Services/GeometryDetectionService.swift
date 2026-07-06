import CoreImage
import Foundation
import Vision

/// One-shot detectors backing the Auto/Level/Vertical/Full Upright modes.
///
/// Apple doesn't expose the vanishing-point detection Lightroom's Upright
/// uses internally, so Vertical/Full/Auto approximate it: find the most
/// prominent rectangle in the frame with `VNDetectRectanglesRequest` and
/// square that up. This works well when a rectangular subject (a building
/// facade, a door, a screen) is in frame, and does nothing useful otherwise.
/// Level is the exception — `VNDetectHorizonRequest` is a real horizon
/// detector and is robust for any photo with a discernible horizon.
enum GeometryDetectionService {
    /// Downsampling before handing an image to Vision — detection accuracy
    /// doesn't need full resolution, and this keeps it fast on large RAWs.
    private static let maxDetectionDimension: CGFloat = 1024

    private static func downsampled(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let scale = min(1, maxDetectionDimension / max(e.width, e.height))
        guard scale < 1 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Degrees to rotate the image level, or `nil` if no horizon was found.
    static func detectLevelAngle(in image: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: downsampled(image), options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return Double(observation.angle) * 180 / .pi
    }

    /// The most prominent rectangle's four corners, normalized (0...1,
    /// bottom-left origin — Vision's convention matches Core Image's), or
    /// `nil` if nothing sufficiently rectangular was found.
    static func detectRectangleCorners(in image: CIImage) -> [CGPoint]? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.2
        request.maximumObservations = 1
        let handler = VNImageRequestHandler(ciImage: downsampled(image), options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return [observation.topLeft, observation.topRight,
                observation.bottomRight, observation.bottomLeft]
    }
}
