import CoreGraphics
import CoreImage
import CoreML
import Foundation

/// On-device "Segment Anything" (SAM, ViT-B) point-prompted segmentation,
/// converted from the official facebookresearch/segment-anything ViT-B
/// checkpoint to two Core ML models (see the repo's `scripts/sam/` for the
/// conversion pipeline that produced `Resources/SAMImageEncoder.mlpackage`
/// and `Resources/SAMMaskDecoder.mlpackage`):
///
/// - The **image encoder** is the expensive part (a ViT-B forward pass) —
///   run once per photo and cached as a ``SAMImageEmbedding``.
/// - The **mask decoder** (prompt encoder + mask head) is cheap — run once
///   per point-prompt interaction against the cached embedding.
///
/// This mirrors SAM's own reference `SamPredictor`: `encode(image:)` is
/// `predictor.set_image()`, `mask(for:points:)` is `predictor.predict()`.
enum SAMSegmentationService {
    /// Both models were exported at this fixed square input size (SAM's own
    /// `image_encoder.img_size`) — images are letterboxed (resized so the
    /// longest side is 1024, padded with black on the bottom/right) rather
    /// than stretched, matching SAM's own `ResizeLongestSide` preprocessing.
    static let inputSize = 1024
    /// The mask decoder was traced with a fixed point count (see
    /// `scripts/sam/convert.py`); unused slots are padded with label `-1`
    /// ("not a point" — SAM's own convention, matches its ONNX export).
    static let maxPoints = 6

    enum SAMError: LocalizedError {
        case modelNotBundled(String)
        case preprocessingFailed
        case predictionFailed

        var errorDescription: String? {
            switch self {
            case .modelNotBundled(let name):
                return "\(name).mlmodelc isn't bundled with this build."
            case .preprocessingFailed:
                return "Couldn't prepare the image for segmentation."
            case .predictionFailed:
                return "Segmentation model prediction failed."
            }
        }
    }

    /// A point prompt: `isForeground == true` marks "part of the region to
    /// select", `false` marks "explicitly exclude" — same as SAM's
    /// point_labels 1/0.
    struct Point {
        let location: CGPoint
        let isForeground: Bool
    }

    /// The image encoder's output for one photo, plus the letterbox geometry
    /// needed to map tap points into the model's 1024x1024 input space and
    /// map its output back to the original image's pixel space.
    struct SAMImageEmbedding {
        let multiArray: MLMultiArray
        let originalSize: CGSize
        let resizedSize: CGSize
    }

    private static let encoderModel: Result<MLModel, Error> = loadModel(named: "SAMImageEncoder")
    private static let decoderModel: Result<MLModel, Error> = loadModel(named: "SAMMaskDecoder")

    private static func loadModel(named name: String) -> Result<MLModel, Error> {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            return .failure(SAMError.modelNotBundled(name))
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            return .success(try MLModel(contentsOf: url, configuration: config))
        } catch {
            return .failure(error)
        }
    }

    /// Runs the (expensive) image encoder once. Cache the result per photo
    /// and reuse it across every Subject/Sky/Background/manual-tap call —
    /// re-encoding per tap is the one thing that would make this feel slow.
    static func encode(_ image: CGImage) throws -> SAMImageEmbedding {
        let model = try encoderModel.get()
        let originalSize = CGSize(width: image.width, height: image.height)
        let scale = CGFloat(inputSize) / max(originalSize.width, originalSize.height)
        let resizedSize = CGSize(
            width: (originalSize.width * scale).rounded(),
            height: (originalSize.height * scale).rounded()
        )
        let inputArray = try letterboxedPixelArray(image, resizedSize: resizedSize)

        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: inputArray)])
        guard let output = try? model.prediction(from: input),
              let embeddings = output.featureValue(for: "image_embeddings")?.multiArrayValue
        else { throw SAMError.predictionFailed }

        return SAMImageEmbedding(multiArray: embeddings, originalSize: originalSize, resizedSize: resizedSize)
    }

    /// Runs the mask decoder against a cached embedding for the given point
    /// prompts, returning a soft (feathered-edge) grayscale mask at the
    /// original image's resolution — white where the local edit should
    /// apply, black where it shouldn't.
    static func mask(for embedding: SAMImageEmbedding, points: [Point]) throws -> CIImage {
        guard !points.isEmpty, points.count <= maxPoints else { throw SAMError.preprocessingFailed }
        let model = try decoderModel.get()

        let scale = CGFloat(inputSize) / max(embedding.originalSize.width, embedding.originalSize.height)
        // Both models declare every input/output as FLOAT16 (coremltools'
        // mlprogram default) — matching that here matters even for these
        // NSNumber-subscript writes, since MLMultiArray still stores the
        // values as float16 underneath and a mismatched constructor dtype
        // would silently fail prediction with a type-mismatch error.
        let coordsArray = try MLMultiArray(shape: [1, NSNumber(value: maxPoints), 2], dataType: .float16)
        let labelsArray = try MLMultiArray(shape: [1, NSNumber(value: maxPoints)], dataType: .float16)
        for i in 0..<maxPoints {
            if i < points.count {
                let p = points[i]
                coordsArray[[0, i, 0] as [NSNumber]] = NSNumber(value: Float(p.location.x * scale))
                coordsArray[[0, i, 1] as [NSNumber]] = NSNumber(value: Float(p.location.y * scale))
                labelsArray[[0, i] as [NSNumber]] = NSNumber(value: p.isForeground ? 1.0 : 0.0)
            } else {
                coordsArray[[0, i, 0] as [NSNumber]] = 0
                coordsArray[[0, i, 1] as [NSNumber]] = 0
                labelsArray[[0, i] as [NSNumber]] = -1.0
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image_embeddings": MLFeatureValue(multiArray: embedding.multiArray),
            "point_coords": MLFeatureValue(multiArray: coordsArray),
            "point_labels": MLFeatureValue(multiArray: labelsArray),
        ])
        guard let output = try? model.prediction(from: input),
              let lowResMasks = output.featureValue(for: "low_res_masks")?.multiArrayValue,
              let iouPredictions = output.featureValue(for: "iou_predictions")?.multiArrayValue
        else { throw SAMError.predictionFailed }

        let bestIndex = bestMaskIndex(iouPredictions)
        return upscaleMask(lowResMasks, maskIndex: bestIndex, embedding: embedding)
    }

    /// "Select Subject" — seeds a single foreground point at the image
    /// center. Most photos are subject-centered; use the manual tap tool to
    /// refine when they aren't.
    static func selectSubject(_ embedding: SAMImageEmbedding) throws -> CIImage {
        let center = CGPoint(x: embedding.originalSize.width / 2, y: embedding.originalSize.height / 2)
        return try mask(for: embedding, points: [Point(location: center, isForeground: true)])
    }

    /// "Select Sky" — seeds a point near top-center, where sky sits in the
    /// overwhelming majority of landscape/travel photos.
    static func selectSky(_ embedding: SAMImageEmbedding) throws -> CIImage {
        let point = CGPoint(x: embedding.originalSize.width / 2, y: embedding.originalSize.height * 0.08)
        return try mask(for: embedding, points: [Point(location: point, isForeground: true)])
    }

    /// "Select Background" — everything outside the subject, i.e. the
    /// subject mask inverted rather than its own SAM call.
    static func selectBackground(_ embedding: SAMImageEmbedding) throws -> CIImage {
        let subject = try selectSubject(embedding)
        return subject.applyingFilter("CIColorInvert")
    }

    private static func bestMaskIndex(_ iouPredictions: MLMultiArray) -> Int {
        var bestIndex = 0
        var bestValue = -Float.greatestFiniteMagnitude
        for i in 0..<iouPredictions.count {
            let value = iouPredictions[i].floatValue
            if value > bestValue {
                bestValue = value
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// Mirrors `Sam.postprocess_masks`: bilinear-upsample the low-res
    /// (256x256) logits to the model's full input size, crop away the
    /// letterbox padding, then resize to the original image's dimensions.
    /// Left as a sigmoid (not thresholded to pure black/white) so the mask
    /// has a naturally soft, feathered edge for blending local adjustments —
    /// a hard `> 0` cutoff would read as an aliased cutout once used to
    /// blend exposure/color edits.
    private static func upscaleMask(
        _ lowResMasks: MLMultiArray, maskIndex: Int, embedding: SAMImageEmbedding
    ) -> CIImage {
        let maskSide = lowResMasks.shape[lowResMasks.shape.count - 1].intValue
        let strideC = maskSide * maskSide
        let base = maskIndex * strideC
        var pixels = [Float](repeating: 0, count: strideC)
        // The decoder declares this output as FLOAT16 — binding to Float32
        // here would reinterpret each 2-byte value as garbage 4-byte floats.
        let ptr = lowResMasks.dataPointer.bindMemory(to: Float16.self, capacity: lowResMasks.count)
        for i in 0..<strideC {
            let logit = Float(ptr[base + i])
            pixels[i] = 1 / (1 + exp(-logit))
        }

        let bitmap = pixels.withUnsafeBufferPointer { buffer -> CIImage in
            let data = Data(buffer: UnsafeBufferPointer(rebasing: buffer[...]))
            return CIImage(
                bitmapData: data, bytesPerRow: maskSide * 4,
                size: CGSize(width: maskSide, height: maskSide), format: .Rf, colorSpace: nil
            )
        }

        // low-res (maskSide) space -> full 1024 input space -> crop off the
        // letterbox padding -> original image size. The valid (non-padding)
        // region sits at the *top* of the 1024 space (matching
        // `letterboxedPixelArray`'s placement), which — since increasing Y
        // is "up" in this still-bottom-left-origin CIImage space — means
        // cropping the region starting at the leftover-height offset, not
        // at y = 0.
        let toInputScale = CGFloat(inputSize) / CGFloat(maskSide)
        let atInputSize = bitmap.transformed(by: CGAffineTransform(scaleX: toInputScale, y: toInputScale))
        let padding = CGFloat(inputSize) - embedding.resizedSize.height
        let cropped = atInputSize.cropped(to: CGRect(
            x: 0, y: padding, width: embedding.resizedSize.width, height: embedding.resizedSize.height))
        // `cropped(to:)` leaves the crop's own origin (0, padding) rather
        // than resetting it to (0, 0) — translate back before scaling, or
        // the leftover offset would get scaled (and shifted) along with it.
        let atOrigin = cropped.transformed(by: CGAffineTransform(translationX: 0, y: -padding))
        let toOriginalScale = embedding.originalSize.width / embedding.resizedSize.width
        return atOrigin.transformed(by: CGAffineTransform(scaleX: toOriginalScale, y: toOriginalScale))
    }

    /// Draws `image` into a black `inputSize`x`inputSize` canvas, resized so
    /// its longest side is `inputSize` and placed at the top-left — SAM's
    /// `ResizeLongestSide` + bottom/right zero-padding — then reads it back
    /// as a 1x3xinputSizexinputSize `Float16` array (matching the encoder's
    /// declared input dtype) in raw 0...255 range (the encoder model itself
    /// applies ImageNet mean/std normalization internally, see
    /// `scripts/sam/convert.py`).
    private static func letterboxedPixelArray(_ image: CGImage, resizedSize: CGSize) throws -> MLMultiArray {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: inputSize, height: inputSize, bitsPerComponent: 8,
                bytesPerRow: inputSize * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw SAMError.preprocessingFailed }
        context.interpolationQuality = .high
        // `CGRect(origin: .zero, ...)` would place `resizedSize` at the
        // *bottom*-left in this bottom-left-origin context — i.e. padding at
        // the top, image at the bottom. SAM's own `ResizeLongestSide` (and
        // the crop back out below) expects the opposite: image at the
        // top-left, padding at the bottom/right. Since row 0 of the raw
        // buffer this context produces is the visual top (`context.draw`
        // handles that flip for us), placing the image at the *top* of this
        // bottom-left-origin space means offsetting its origin by the
        // leftover height.
        context.draw(image, in: CGRect(
            x: 0, y: CGFloat(inputSize) - resizedSize.height,
            width: resizedSize.width, height: resizedSize.height))
        guard let data = context.data else { throw SAMError.preprocessingFailed }
        let rgba = data.bindMemory(to: UInt8.self, capacity: inputSize * inputSize * 4)

        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: inputSize), NSNumber(value: inputSize)], dataType: .float16)
        let plane = inputSize * inputSize
        let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: 3 * plane)
        for y in 0..<inputSize {
            for x in 0..<inputSize {
                let srcOffset = (y * inputSize + x) * 4
                let dstOffset = y * inputSize + x
                ptr[dstOffset] = Float16(rgba[srcOffset])                  // R
                ptr[plane + dstOffset] = Float16(rgba[srcOffset + 1])       // G
                ptr[2 * plane + dstOffset] = Float16(rgba[srcOffset + 2])  // B
            }
        }
        return array
    }
}
