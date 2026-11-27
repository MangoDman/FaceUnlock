import CoreImage
import CoreML

/// Aligns a face to 112×112 and turns it into a 128-number identity vector (SFace).
final class FaceEmbedder {
    private let model: MLModel
    private let context = CIContext()

    init() throws {
        guard let url = Bundle.main.url(forResource: "FaceEmbedder", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        model = try MLModel(contentsOf: url)
    }

    /// `points` are in `FaceMath.template` order, bottom-left origin.
    func embedding(for pixels: CVPixelBuffer, points: [CGPoint]) -> [Float]? {
        let target = FaceMath.template.map { CGPoint(x: $0.x, y: 112 - $0.y) }
        guard let transform = FaceMath.similarityTransform(from: points, to: target) else { return nil }
        let aligned = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
            .cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))
        return embedding(forAligned: aligned)
    }

    func embedding(forAligned image: CIImage) -> [Float]? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        context.render(image, to: buffer)
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["data": MLFeatureValue(pixelBuffer: buffer)]),
              let output = try? model.prediction(from: input),
              let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return FaceMath.normalized((0..<array.count).map { array[$0].floatValue })
    }
}
