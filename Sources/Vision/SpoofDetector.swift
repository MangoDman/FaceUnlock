import CoreImage
import CoreML

/// A small neural network (MiniFASNetV2-SE) that judges whether a face crop is a live person or a
/// photo or screen. Positive scores mean live.
final class SpoofDetector {
    private let model: MLModel
    private let context = CIContext()

    init() throws {
        guard let url = Bundle.main.url(forResource: "AntiSpoof", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        model = try MLModel(contentsOf: url)
    }

    /// `face` is Vision's normalized box. The model expects a square 1.5 times the face.
    func score(_ image: CIImage, face: CGRect) -> Float? {
        guard let buffer = input(image, face: face),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: buffer)]),
              let output = try? model.prediction(from: input),
              let logits = output.featureValue(for: "logits")?.multiArrayValue, logits.count == 2 else { return nil }
        return logits[0].floatValue - logits[1].floatValue
    }

    /// The 128×128 picture the model sees.
    func input(_ image: CIImage, face: CGRect) -> CVPixelBuffer? {
        let extent = image.extent
        let side = max(face.width * extent.width, face.height * extent.height) * 1.5
        let crop = CGRect(x: face.midX * extent.width - side / 2, y: face.midY * extent.height - side / 2,
                          width: side, height: side)
        let square = image.clampedToExtent().cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: 128 / side, y: 128 / side))
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        context.render(square, to: buffer, bounds: CGRect(x: 0, y: 0, width: 128, height: 128),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }
}
