import CoreGraphics
import Foundation

/// What one frame says about whether the face is really there.
struct LivenessFrame {
    /// Eye height / width, averaged over both eyes.
    var eyeOpenness: CGFloat
    /// Eyes-to-mouth distance / eye-to-eye distance: how squashed the face looks from this angle.
    var faceHeight: CGFloat = 1
    /// Where the nose tip sits, measured against the eyes and mouth. See `NoseDepth`.
    var noseDepth: CGFloat?
    /// A large flat reflection lies across the face, as on glass.
    var hasGlare = false
    /// The face sits inside a device-sized rectangle.
    var isFramed = false
}

enum LivenessProof: String { case blink, headTurn = "head depth" }
enum SpoofSign: String { case glare = "screen glare", frame = "device frame" }

enum LivenessVerdict: Equatable {
    case undecided
    /// Nil when no proof was asked for and nothing looked wrong.
    case live(LivenessProof?)
    case spoof(SpoofSign)
}

/// Judges a scan frame by frame. Signs of a screen or photo always win. Beyond that, and only
/// when proof is required, the face must blink or show depth as it turns.
struct LivenessMonitor {
    /// False: a face is accepted once a few frames show nothing wrong.
    var requiresProof: Bool

    /// A spoof sign must show on this many frames, and on most of those seen so far. A real face
    /// catches the odd reflection; a screen or print keeps showing it. Once decided it stays.
    static let framesToReject = 3
    static let framesBeforeAccepting = 3

    private var frames = 0
    private var glareFrames = 0
    private var framedFrames = 0
    private var blink = BlinkDetector()
    private var depth = NoseDepth()
    private var proof: LivenessProof?
    private var sign: SpoofSign?

    init(requiresProof: Bool) { self.requiresProof = requiresProof }

    /// Forgets everything: the next frame may belong to a different face.
    mutating func reset() { self = LivenessMonitor(requiresProof: requiresProof) }

    mutating func observe(_ frame: LivenessFrame, at time: TimeInterval) -> LivenessVerdict {
        frames += 1
        if frame.hasGlare { glareFrames += 1 }
        if frame.isFramed { framedFrames += 1 }
        if sign == nil, persists(glareFrames) { sign = .glare }
        if sign == nil, persists(framedFrames) { sign = .frame }

        // Both detectors see every frame, whichever proves it first.
        let blinked = blink.observe(frame.eyeOpenness, faceHeight: frame.faceHeight, at: time)
        let turned = frame.noseDepth.map { depth.observe($0, at: time) } ?? false
        if proof == nil { proof = blinked ? .blink : turned ? .headTurn : nil }

        if let sign { return .spoof(sign) }
        if !requiresProof { return frames >= Self.framesBeforeAccepting ? .live(nil) : .undecided }
        return proof.map { .live($0) } ?? .undecided
    }

    private func persists(_ count: Int) -> Bool { count >= Self.framesToReject && count * 2 > frames }
}

/// A blink is eyes that were open, shut briefly and opened again, while the rest of the face
/// stayed put. Based on the eye aspect ratio (Soukupová and Čech, 2016), with two additions
/// against pictures: openness is judged relative to how squashed the whole face looks, and a
/// face that changes shape at the same moment doesn't count. Tipping a photograph squashes
/// its eyes, but squashes everything else with them.
struct BlinkDetector {
    /// Shut below this share of the usual openness, open again above the other.
    static let shut: CGFloat = 0.65
    static let reopened: CGFloat = 0.8
    /// Longer than this and the eyes were closed, not blinking. Seconds, so it doesn't depend
    /// on the camera's frame rate.
    static let longestBlink: TimeInterval = 0.5
    /// How much the face's own proportions may differ during a blink.
    static let steadiness: CGFloat = 0.12

    private var open: [(openness: CGFloat, height: CGFloat)] = []
    private var shutSince: TimeInterval?
    private var faceMoved = false

    mutating func observe(_ openness: CGFloat, faceHeight: CGFloat, at time: TimeInterval) -> Bool {
        guard openness > 0, faceHeight > 0 else { return false }
        let relative = openness / faceHeight
        guard open.count >= 3 else {
            open.append((relative, faceHeight))
            return false
        }
        let usual = open.map(\.openness).sorted()[open.count / 2]
        let height = open.map(\.height).sorted()[open.count / 2]
        let moved = abs(faceHeight / height - 1) > Self.steadiness
        if relative < usual * Self.shut {
            if shutSince == nil { shutSince = time }
            faceMoved = faceMoved || moved
            return false
        }
        guard relative > usual * Self.reopened else { return false }
        let blinked = shutSince.map { time - $0 <= Self.longestBlink } ?? false
        let steady = !faceMoved && !moved
        shutSince = nil
        faceMoved = false
        open = Array((open + [(relative, faceHeight)]).suffix(15))
        return blinked && steady
    }
}

/// Tells a head from a picture of one. Take the two eyes and the two mouth corners, which lie
/// roughly flat, as the corners of a square, and ask where in that square the nose tip falls.
/// However a flat picture is moved, tilted or held up close, perspective included, the answer
/// stays the same. The nose stands out from a real face, so there it changes as the head turns.
struct NoseDepth {
    /// How far the answer must move: about a 12 degree turn of a real head.
    static let required: CGFloat = 0.08
    static let window: TimeInterval = 2.5

    private var recent: [CGFloat] = []
    private var settled: [(time: TimeInterval, value: CGFloat)] = []

    /// The nose tip's sideways position in the eyes-and-mouth square; 0 is the middle.
    static func measure(leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint,
                        leftMouth: CGPoint, rightMouth: CGPoint) -> CGFloat? {
        // The projective map from the unit square onto the four points (Heckbert, 1989)...
        let p0 = leftEye, p1 = rightEye, p2 = rightMouth, p3 = leftMouth
        let sx = p0.x - p1.x + p2.x - p3.x, sy = p0.y - p1.y + p2.y - p3.y
        let dx1 = p1.x - p2.x, dy1 = p1.y - p2.y, dx2 = p3.x - p2.x, dy2 = p3.y - p2.y
        let denominator = dx1 * dy2 - dx2 * dy1
        guard abs(denominator) > 1e-9 else { return nil }
        let g = (sx * dy2 - dx2 * sy) / denominator
        let h = (dx1 * sy - sx * dy1) / denominator
        let a = p1.x - p0.x + g * p1.x, b = p3.x - p0.x + h * p3.x, c = p0.x
        let d = p1.y - p0.y + g * p1.y, e = p3.y - p0.y + h * p3.y, f = p0.y
        // ...and run backwards for the nose.
        let u = (e - f * h) * nose.x + (c * h - b) * nose.y + (b * f - c * e)
        let w = (d * h - e * g) * nose.x + (b * g - a * h) * nose.y + (a * e - b * d)
        guard abs(w) > 1e-9 else { return nil }
        return u / w - 0.5
    }

    mutating func observe(_ value: CGFloat, at time: TimeInterval) -> Bool {
        // Wild values are lost landmarks, not a turned head.
        guard abs(value) < 0.6 else { return false }
        // A median of seven ignores a few jumpy frames.
        recent = Array((recent + [value]).suffix(7))
        guard recent.count == 7 else { return false }
        settled.append((time, recent.sorted()[3]))
        settled.removeAll { time - $0.time > Self.window }
        let values = settled.map(\.value)
        return (values.max() ?? 0) - (values.min() ?? 0) >= Self.required
    }
}
