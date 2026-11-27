import CoreGraphics
import Foundation

/// The setup scan: position → turn left/right/up/down → look straight → done.
struct EnrollmentMachine {
    enum Direction: CaseIterable { case up, right, down, left }
    enum Phase: Equatable { case positioning, turning, lookStraight, complete }

    enum Guidance: Equatable {
        case positionFace, turnHead, turnedTooFar, lookStraight, tooDark, moveCloser, oneFaceOnly, done

        var title: String? { self == .turnedTooFar ? "Head Turned Too Far" : nil }

        var message: String {
            switch self {
            case .positionFace: "Position your face within the frame."
            case .turnHead: "Slowly turn your head left, right, up, and down."
            case .turnedTooFar: "Slowly turn your head back toward the camera."
            case .lookStraight: "Look straight ahead."
            case .tooDark: "More light is needed to see your face."
            case .moveCloser: "Move a little closer to the camera."
            case .oneFaceOnly: "Make sure only your face is in view."
            case .done: "Face Recognition is now set up."
            }
        }
    }

    /// Accessibility option: skip the head turns for people with limited head movement.
    var requiresHeadTurns = true
    private(set) var phase = Phase.positioning
    private(set) var guidance = Guidance.positionFace
    private(set) var captured: Set<Direction> = []
    /// How far the head is turned right now, in units of "enough to capture":
    /// +x toward screen right in the mirrored preview, +y down.
    private(set) var turn = CGVector.zero

    private var baseline = FaceSample()
    private var holdStart: TimeInterval?
    private var holding: Direction?

    /// Feeds one frame. Returns true when this frame should be saved as a face template.
    mutating func process(_ sample: FaceSample, at time: TimeInterval) -> Bool {
        guard phase != .complete else { return false }

        let problem: Guidance? =
            sample.isTooDark ? .tooDark
            : sample.faceCount > 1 ? .oneFaceOnly
            : sample.faceCount == 0 ? (phase == .turning ? .turnedTooFar : .positionFace)
            : sample.size < 0.2 ? .moveCloser
            : nil
        if let problem {
            guidance = problem
            holdStart = nil
            return false
        }

        switch phase {
        case .positioning:
            guidance = .positionFace
            guard sample.isCentred, sample.isFacingScreen, held(for: 0.8, at: time) else {
                if !sample.isCentred || !sample.isFacingScreen { holdStart = nil }
                return false
            }
            baseline = sample
            holdStart = nil
            phase = requiresHeadTurns ? .turning : .lookStraight
            guidance = requiresHeadTurns ? .turnHead : .lookStraight
            return true

        case .turning:
            let motion = movement(sample)
            turn = CGVector(dx: -motion.yawSign * motion.yaw, dy: motion.pitchSign * motion.pitch)
            if motion.tooFar {
                guidance = .turnedTooFar
                holdStart = nil
                return false
            }
            guidance = .turnHead
            // Pick whichever axis is further past what counts as a turn.
            var direction: Direction?
            if max(motion.yaw, motion.pitch) >= 1 {
                if motion.yaw >= motion.pitch {
                    direction = motion.yawSign > 0 ? .left : .right
                } else {
                    direction = motion.pitchSign < 0 ? .up : .down
                }
            }
            guard let direction, !captured.contains(direction) else {
                holdStart = nil
                holding = nil
                return false
            }
            if direction != holding {
                holding = direction
                holdStart = nil
            }
            guard held(for: 0.15, at: time) else { return false }
            captured.insert(direction)
            holdStart = nil
            if captured.count == Direction.allCases.count {
                phase = .lookStraight
                guidance = .lookStraight
                turn = .zero
            }
            return true

        case .lookStraight:
            guidance = .lookStraight
            let motion = movement(sample)
            guard motion.yaw < 0.65, motion.pitch < 0.65 else {
                holdStart = nil
                return false
            }
            guard held(for: 0.6, at: time) else { return false }
            phase = .complete
            guidance = .done
            captured = Set(Direction.allCases)
            return true

        case .complete:
            return false
        }
    }

    /// How far the head has moved from where it started, in units of "a deliberate turn" (1 is
    /// enough). Two measurements are taken and the stronger one counts, because either can be
    /// weak for a particular face: where the nose sits between the eyes, and Vision's head angle.
    private func movement(_ sample: FaceSample) -> (yaw: CGFloat, yawSign: CGFloat, pitch: CGFloat,
                                                    pitchSign: CGFloat, tooFar: Bool) {
        let dy = sample.yaw - baseline.yaw
        let dp = sample.pitch - baseline.pitch
        let angleYaw = abs((sample.headYaw ?? 0) - (baseline.headYaw ?? 0))
        let anglePitch = abs((sample.headPitch ?? 0) - (baseline.headPitch ?? 0))
        // The nose has to move a little in a direction before that direction is believed.
        let yaw = abs(dy) > 0.035 ? max(abs(dy) / 0.13, angleYaw / 0.30) : 0
        let pitch = abs(dp) > 0.018 ? max(abs(dp) / 0.06, anglePitch / 0.18) : 0
        let tooFar = abs(dy) > 0.85 || angleYaw > 0.95 || abs(dp) > 0.34
        return (yaw, dy > 0 ? 1 : -1, pitch, dp > 0 ? 1 : -1, tooFar)
    }

    /// The next side still needed, in the order the lesson shows them.
    var nextNeeded: Direction? {
        [.left, .right, .up, .down].first { !captured.contains($0) }
    }

    private mutating func held(for duration: TimeInterval, at time: TimeInterval) -> Bool {
        guard let start = holdStart else {
            holdStart = time
            return false
        }
        return time - start >= duration
    }
}
