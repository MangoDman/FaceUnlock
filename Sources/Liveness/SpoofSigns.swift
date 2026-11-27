import CoreImage
import Vision

/// Looks for the two give-aways of a face shown on something: light bouncing off glass, and the
/// edges of the thing itself. Either can be fooled; they only ever add a reason to refuse.
enum SpoofSigns {
    // MARK: Glare

    /// A reflection must cover this much of the face, in one piece. Skin shines in small specks.
    static let glareShare = 0.04
    /// Rows left out, as shares of the face box from its top: that is where spectacles reflect.
    static let eyeBand = 0.22...0.5
    /// Smaller faces don't have the detail to judge.
    static let smallestFace: CGFloat = 60

    /// `face` is Vision's normalized box.
    static func hasGlare(_ image: CIImage, face: CGRect, context: CIContext) -> Bool {
        let extent = image.extent
        let box = CGRect(x: face.minX * extent.width, y: face.minY * extent.height,
                         width: face.width * extent.width, height: face.height * extent.height)
            .intersection(extent)
        guard box.width >= smallestFace, box.height >= smallestFace else { return false }
        let side = 96
        let scaled = image.cropped(to: box)
            .transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / box.width, y: CGFloat(side) / box.height))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: side * 4,
                       bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: nil)
        // Burnt out and colourless.
        let white = (0..<side * side).map { index -> Bool in
            if eyeBand.contains(Double(index / side) / Double(side)) { return false }
            let rgb = pixels[index * 4..<index * 4 + 3]
            let high = rgb.max()!, low = rgb.min()!
            return high >= 250 && high - low <= 16
        }
        return Double(largestPatch(white, width: side)) >= Double(side * side) * glareShare
    }

    /// Size of the biggest group of marked cells that touch side by side.
    static func largestPatch(_ marked: [Bool], width: Int) -> Int {
        var unvisited = marked
        var largest = 0
        for start in unvisited.indices where unvisited[start] {
            unvisited[start] = false
            var stack = [start], size = 0
            while let index = stack.popLast() {
                size += 1
                let column = index % width
                for next in [column > 0 ? index - 1 : -1, column < width - 1 ? index + 1 : -1,
                             index - width, index + width]
                where unvisited.indices.contains(next) && unvisited[next] {
                    unvisited[next] = false
                    stack.append(next)
                }
            }
            largest = max(largest, size)
        }
        return largest
    }

    // MARK: Device frame

    static func isFramed(_ pixels: CVPixelBuffer, face: CGRect) -> Bool {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumSize = 0.2
        request.maximumObservations = 4
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 25
        guard (try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])) != nil
        else { return false }
        return (request.results ?? []).contains {
            surrounds([$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft], face: face)
        }
    }

    /// True if the four corners enclose the face and are the size of something held up to the
    /// camera. A door or window behind you is either far bigger or cuts across your head.
    static func surrounds(_ corners: [CGPoint], face: CGRect) -> Bool {
        let path = CGMutablePath()
        path.addLines(between: corners)
        path.closeSubpath()
        var twiceArea: CGFloat = 0
        for (index, point) in corners.enumerated() {
            let next = corners[(index + 1) % corners.count]
            twiceArea += point.x * next.y - next.x * point.y
        }
        let ratio = abs(twiceArea) / 2 / (face.width * face.height)
        guard ratio > 1.2, ratio < 6 else { return false }
        // Vision's face box is generous, so a screen may clip its very edge.
        let core = face.insetBy(dx: face.width * 0.08, dy: face.height * 0.08)
        return [CGPoint(x: core.minX, y: core.minY), CGPoint(x: core.maxX, y: core.minY),
                CGPoint(x: core.minX, y: core.maxY), CGPoint(x: core.maxX, y: core.maxY)]
            .allSatisfy { path.contains($0) }
    }
}
