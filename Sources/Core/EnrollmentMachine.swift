import CoreGraphics
import Foundation

/// The setup scan: position → turn left/right/up/down → look straight → done.
struct EnrollmentMachine {
    enum Direction: CaseIterable { case up, right, down, left }
    enum Phase: Equatable { case positioning, turning, lookStraight, complete }

    enum Guidance: Equatable {
        case positionFace, noFace, outOfView, turnHead, turnedTooFar, lookStraight, tooDark, moveCloser, oneFaceOnly, done

        var title: String? {
            switch self {
            case .noFace: "No Face Detected"
            case .outOfView: "Face Out of View"
            case .turnedTooFar: "Head Turned Too Far"
            default: nil
            }
        }

        var message: String {
            switch self {
            case .positionFace, .noFace: "Position your face within the frame."
            case .outOfView: "Reposition your face within the frame."
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
    /// When the face was last as wanted, so one stray frame doesn't restart a hold.
    private var lastGood: TimeInterval?
    /// The head angles seen while settling, averaged into where "straight ahead" is for you.
    private var settling: [FaceSample] = []
    /// When this step, or the last captured side, began. Long waits make the scan more forgiving.
    private var since: TimeInterval?

    /// After this long on one step, a smaller movement is accepted.
    static let patience: TimeInterval = 4
    /// After this long looking for the last picture, the scan finishes with what it has.
    static let longestFinish: TimeInterval = 2

    /// Roughly facing the camera. Vision's head angles are used where it gives them: they stay
    /// steady where the nose's place between the eyes can jump about, for instance with glasses.
    /// The camera sits above the screen, and to one side for anyone using a second display, so
    /// this is generous.
    private func isRoughlyAhead(_ sample: FaceSample) -> Bool {
        if let yaw = sample.headYaw, let pitch = sample.headPitch { return abs(yaw) < 0.32 && abs(pitch) < 0.48 }
        return sample.isFacingScreen
    }

    /// True once things have been right for `duration`, forgiving gaps shorter than a quarter second.
    private mutating func steady(_ good: Bool, for duration: TimeInterval, at time: TimeInterval) -> Bool {
        if good {
            lastGood = time
            return held(for: duration, at: time)
        }
        if time - (lastGood ?? -1) > 0.25 { holdStart = nil }
        return false
    }

    /// Feeds one frame. Returns true when this frame should be saved as a face template.
    mutating func process(_ sample: FaceSample, at time: TimeInterval) -> Bool {
        guard phase != .complete else { return false }

        let problem: Guidance? =
            sample.isTooDark ? .tooDark
            : sample.faceCount > 1 ? .oneFaceOnly
            : sample.faceCount == 0 ? (phase == .positioning ? .noFace : .outOfView)
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
            let good = sample.isCentred && isRoughlyAhead(sample)
            if good { settling.append(sample) }
            guard steady(good, for: 0.3, at: time) else {
                if holdStart == nil { settling = [] }
                return false
            }
            baseline = Self.average(settling) ?? sample
            holdStart = nil
            since = time
            phase = requiresHeadTurns ? .turning : .lookStraight
            guidance = requiresHeadTurns ? .turnHead : .lookStraight
            return true

        case .turning:
            if since == nil { since = time }
            let ease: CGFloat = time - (since ?? time) > Self.patience ? 1.35 : 1
            var motion = movement(sample)
            motion.yaw *= ease
            motion.pitch *= ease
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
            guard held(for: 0.1, at: time) else { return false }
            captured.insert(direction)
            holdStart = nil
            since = time
            if captured.count == Direction.allCases.count {
                phase = .lookStraight
                guidance = .lookStraight
                turn = .zero
            }
            return true

        case .lookStraight:
            guidance = .lookStraight
            if since == nil { since = time }
            // Facing the camera again is enough: nobody can return to exactly the same spot. And
            // if even that takes long, every side is already captured, so finish.
            let waitedLong = time - (since ?? time) > Self.longestFinish
            // No longer turned either way, so the last picture isn't of the final side.
            let back = movement(sample)
            let ahead = isRoughlyAhead(sample) && back.yaw < 0.9 && back.pitch < 0.9
            guard steady(ahead, for: 0.2, at: time) || waitedLong else { return false }
            phase = .complete
            guidance = .done
            captured = Set(Direction.allCases)
            return true

        case .complete:
            return false
        }
    }

    /// How far the head has moved from where it started, in units of "a deliberate turn" (1 is
    /// enough). Vision's head angles decide, signed the same way as the nose measurements:
    /// +yaw toward the user's left, +pitch downward. The nose is only used where there are none.
    private func movement(_ sample: FaceSample) -> (yaw: CGFloat, yawSign: CGFloat, pitch: CGFloat,
                                                    pitchSign: CGFloat, tooFar: Bool) {
        if let yaw = sample.headYaw, let pitch = sample.headPitch,
           let startYaw = baseline.headYaw, let startPitch = baseline.headPitch {
            let turn = yaw - startYaw, nod = pitch - startPitch
            return (abs(turn) / 0.2, turn > 0 ? 1 : -1, abs(nod) / 0.15, nod > 0 ? 1 : -1,
                    abs(turn) > 1.3 || abs(nod) > 1.1)
        }
        let dy = sample.yaw - baseline.yaw
        let dp = sample.pitch - baseline.pitch
        let yaw = abs(dy) > 0.035 ? abs(dy) / 0.13 : 0
        let pitch = abs(dp) > 0.018 ? abs(dp) / 0.06 : 0
        let tooFar = abs(dy) > 0.85 || abs(dp) > 0.34
        return (yaw, dy > 0 ? 1 : -1, pitch, dp > 0 ? 1 : -1, tooFar)
    }

    private static func average(_ samples: [FaceSample]) -> FaceSample? {
        guard var result = samples.last else { return nil }
        func mean(_ values: [CGFloat]) -> CGFloat? { values.isEmpty ? nil : values.reduce(0, +) / CGFloat(values.count) }
        result.yaw = mean(samples.map(\.yaw)) ?? result.yaw
        result.pitch = mean(samples.map(\.pitch)) ?? result.pitch
        result.headYaw = mean(samples.compactMap(\.headYaw))
        result.headPitch = mean(samples.compactMap(\.headPitch))
        return result
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
