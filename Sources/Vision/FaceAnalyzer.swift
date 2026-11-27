import CoreImage
import Vision

/// Vision turns a frame into a `FaceSample` plus the five points used for alignment.
struct FaceAnalyzer {
    struct Result {
        var sample: FaceSample
        /// Template order, in image pixels with a bottom-left origin (Core Image space).
        var points: [CGPoint]?
        /// Spoof-check measurements, only gathered when a scan asks for them.
        var liveness: LivenessFrame? = nil
        /// Face centre and width (normalized), to notice when the face is swapped.
        var box: CGRect? = nil
        /// Anti-spoof model score; positive means live.
        var modelScore: Float? = nil
    }

    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let spoofDetector = try? SpoofDetector()

    var hasSpoofModel: Bool { spoofDetector != nil }

    func analyze(_ pixels: CVPixelBuffer, liveness: Bool = false, spoofScore: Bool = false) -> Result {
        let width = CGFloat(CVPixelBufferGetWidth(pixels)), height = CGFloat(CVPixelBufferGetHeight(pixels))
        // Rectangles first: that request estimates the head angles used during setup.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        try? handler.perform([rectangles])
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = rectangles.results ?? []
        try? handler.perform([request])
        // Ignore small faces in the background.
        let faces = (request.results ?? []).filter { $0.boundingBox.height > 0.12 }

        var sample = FaceSample.none
        sample.brightness = brightness(of: CIImage(cvPixelBuffer: pixels))
        guard let face = faces.max(by: { $0.boundingBox.height < $1.boundingBox.height }),
              let marks = face.landmarks else { return Result(sample: sample, points: nil) }

        let size = CGSize(width: width, height: height)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: size) ?? [] }
        func centre(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.reduce(0) { $0 + $1.x } / CGFloat(max(p.count, 1)),
                    y: p.reduce(0) { $0 + $1.y } / CGFloat(max(p.count, 1)))
        }

        let eyeA = points(marks.leftEye), eyeB = points(marks.rightEye)
        let nose = points(marks.noseCrest), lips = points(marks.outerLips)
        guard !eyeA.isEmpty, !eyeB.isEmpty, !nose.isEmpty, !lips.isEmpty else {
            return Result(sample: sample, points: nil)
        }
        let pupilA = points(marks.leftPupil).first ?? centre(eyeA)
        let pupilB = points(marks.rightPupil).first ?? centre(eyeB)
        let eyes = [pupilA, pupilB].sorted { $0.x < $1.x }
        let tip = nose.min { $0.y < $1.y }!  // lowest point of the crest (bottom-left origin)
        let mouth = [lips.min { $0.x < $1.x }!, lips.max { $0.x < $1.x }!]

        let eyeMid = centre(eyes), mouthMid = centre(mouth)
        let eyeDistance = hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y)
        // Head axes, so tilting the head doesn't read as turning it.
        let across = CGVector(dx: (eyes[1].x - eyes[0].x) / eyeDistance, dy: (eyes[1].y - eyes[0].y) / eyeDistance)
        let down = CGVector(dx: across.dy, dy: -across.dx)
        func project(_ p: CGPoint, _ axis: CGVector) -> CGFloat {
            (p.x - eyeMid.x) * axis.dx + (p.y - eyeMid.y) * axis.dy
        }
        func openness(_ eye: [CGPoint]) -> CGFloat {
            let xs = eye.map { project($0, across) }, ys = eye.map { project($0, down) }
            let w = (xs.max() ?? 0) - (xs.min() ?? 0)
            return w > 0 ? ((ys.max() ?? 0) - (ys.min() ?? 0)) / w : 0
        }

        let box = face.boundingBox
        sample.faceCount = faces.count
        sample.offset = CGSize(width: (box.midX - 0.5) * width / height, height: box.midY - 0.5)
        sample.size = box.height
        sample.yaw = project(tip, across) / eyeDistance
        let mouthDepth = project(mouthMid, down)
        sample.pitch = mouthDepth != 0 ? project(tip, down) / mouthDepth : 0.55
        sample.eyeOpenness = (openness(eyeA) + openness(eyeB)) / 2
        // Judge light on the face itself; a bright window behind shouldn't hide a dark face.
        sample.brightness = brightness(of: CIImage(cvPixelBuffer: pixels).cropped(to: CGRect(
            x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)))

        let angles = rectangles.results?.max { $0.boundingBox.height < $1.boundingBox.height }
        sample.headYaw = angles?.yaw.map { CGFloat($0.doubleValue) }
        sample.headPitch = angles?.pitch.map { CGFloat($0.doubleValue) }

        var result = Result(sample: sample, points: [eyes[0], eyes[1], tip, mouth[0], mouth[1]], box: box)
        if liveness {
            let image = CIImage(cvPixelBuffer: pixels)
            result.liveness = LivenessFrame(
                eyeOpenness: sample.eyeOpenness,
                faceHeight: mouthDepth / eyeDistance,
                // Small faces are too coarse to measure depth from.
                noseDepth: sample.size < 0.2 ? nil : NoseDepth.measure(
                    leftEye: eyes[0], rightEye: eyes[1], nose: tip, leftMouth: mouth[0], rightMouth: mouth[1]),
                hasGlare: SpoofSigns.hasGlare(image, face: box, context: context),
                isFramed: SpoofSigns.isFramed(pixels, face: box))
            if spoofScore { result.modelScore = spoofDetector?.score(image, face: box) }
        }
        return result
    }

    private func brightness(of image: CIImage) -> CGFloat {
        let average = image.applyingFilter("CIAreaAverage",
                                           parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return (0.299 * CGFloat(pixel[0]) + 0.587 * CGFloat(pixel[1]) + 0.114 * CGFloat(pixel[2])) / 255
    }
}
