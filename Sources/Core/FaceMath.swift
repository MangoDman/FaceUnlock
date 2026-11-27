import CoreGraphics

enum FaceMath {
    /// Where eyes, nose and mouth corners sit in a 112×112 aligned face (top-left origin),
    /// ordered image-left eye, image-right eye, nose tip, image-left mouth, image-right mouth.
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares rotation + uniform scale + translation taking `source` onto `target`.
    static func similarityTransform(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = CGFloat(source.count)
        func mean(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.reduce(0) { $0 + $1.x } / n, y: p.reduce(0) { $0 + $1.y } / n)
        }
        let ms = mean(source), mt = mean(target)
        var a: CGFloat = 0, b: CGFloat = 0, d: CGFloat = 0
        for (s, t) in zip(source, target) {
            let sx = s.x - ms.x, sy = s.y - ms.y, tx = t.x - mt.x, ty = t.y - mt.y
            a += sx * tx + sy * ty
            b += sx * ty - sy * tx
            d += sx * sx + sy * sy
        }
        guard d > 0 else { return nil }
        let c = a / d, s = b / d
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: mt.x - (c * ms.x - s * ms.y), ty: mt.y - (s * ms.x + c * ms.y))
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? v.map { $0 / length } : v
    }

    /// Cosine similarity of two normalized vectors.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func bestSimilarity(_ probe: [Float], in templates: [[Float]]) -> Float {
        templates.map { similarity(probe, $0) }.max() ?? -1
    }
}
