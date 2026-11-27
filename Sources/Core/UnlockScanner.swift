import CoreGraphics
import Foundation

/// Decides, frame by frame, whether a scan should unlock. Several independent gates must all pass:
/// identity (on the unlocking frame), liveness cues, the anti-spoof model and, at the highest
/// protection, a random head-turn challenge that a recorded video can't anticipate.
struct UnlockScanner {
    enum Outcome: Equatable {
        case scanning, recognized
        /// A face was there but it wasn't the owner. Counts toward the failure limit.
        case notRecognized
        /// The owner, but no proof of a live face in time. Not counted as a failure.
        case noLiveness
        /// The owner, but never looking at the screen. Not counted as a failure.
        case notAttentive
        /// A screen or photo was detected.
        case spoof
        /// Someone else is also in view and the user asked to be alone.
        case notAlone
        case noFace
    }

    /// A turn of the user's own head.
    enum Turn: Equatable {
        case left, right
        var instruction: String { self == .left ? "Turn Your Head Left" : "Turn Your Head Right" }
    }

    struct Rules {
        /// Cosine similarity needed. OpenCV suggests 0.363 for SFace on benchmarks; these are
        /// deliberately stricter because a false match opens the Mac.
        var threshold: Float = 0.55
        var requiredMatches = 2
        var requiresAttention = true
        var requiresSolitude = false
        var usesSpoofModel = false
        var challenge: Turn?
        /// How long a face may keep failing to match before the scan gives up.
        var wrongFaceGrace: TimeInterval = 2.5
        var timeout: TimeInterval = 8
    }

    /// What the liveness analyzer currently says.
    enum Liveness: Equatable { case pending, confirmed, denied }

    var rules: Rules
    private(set) var matches = 0
    /// True when the liveness analyzer must be restarted because the face changed.
    private(set) var faceChanged = false
    private(set) var needsLiveness = false
    /// Set while waiting for the head turn.
    private(set) var challengePrompt: Turn?
    /// Median anti-spoof score over the last few frames.
    private(set) var spoofScore: Float?

    private var start: TimeInterval?
    private var mismatchStart: TimeInterval?
    private var lostSince: TimeInterval?
    private var lastBox: CGRect?
    private var everMatched = false
    private var sawFace = false
    private var sawOwner = false
    /// Why the last matching frame didn't count, for the log.
    private(set) var heldBack: FaceSample?
    private var strangerFrames = 0
    private var crowdedFrames = 0
    private var spoofScores: [Float] = []
    private var challengeStart: TimeInterval?
    private var challengeBaseline: CGFloat = 0
    private var challengePassed = false

    init(rules: Rules = Rules()) { self.rules = rules }

    mutating func process(_ sample: FaceSample, box: CGRect?, similarity: Float?, liveness: Liveness,
                          modelScore: Float? = nil, at time: TimeInterval) -> Outcome {
        if start == nil { start = time }
        // The head turn gets its own time on top of the scan.
        let limit = rules.timeout + (rules.challenge == nil ? 0 : 5)
        let timedOut = time - (start ?? time) >= limit
        faceChanged = false

        if liveness == .denied { return .spoof }
        crowdedFrames = sample.faceCount > 1 ? crowdedFrames + 1 : 0
        if rules.requiresSolitude, crowdedFrames >= 4 { return .notAlone }

        let usable = sample.faceCount >= 1 && !sample.isTooDark && similarity != nil
        guard usable, let similarity else {
            matches = 0
            mismatchStart = nil
            if lostSince == nil { lostSince = time }
            if time - (lostSince ?? time) > 0.7 { forgetFace() }
            return timedOut ? finalOutcome : .scanning
        }
        sawFace = true
        lostSince = nil

        // A jump in position, or clearly someone else for several frames, is a different face:
        // proof given by one face must never be spent by another.
        if let box, let lastBox, hypot(box.midX - lastBox.midX, box.midY - lastBox.midY) > lastBox.width * 0.6 {
            forgetFace()
        }
        lastBox = box
        strangerFrames = similarity < 0.25 ? strangerFrames + 1 : 0
        if strangerFrames == 3 { forgetFace() }

        if let modelScore {
            spoofScores = Array((spoofScores + [modelScore]).suffix(9))
            spoofScore = spoofScores.sorted()[spoofScores.count / 2]
        }
        if rules.usesSpoofModel, spoofScores.count >= 9, let spoofScore, spoofScore < -1 { return .spoof }
        let modelSatisfied = !rules.usesSpoofModel || (spoofScores.count >= 3 && (spoofScore ?? -1) > 0)

        let attentive = !rules.requiresAttention || sample.isAttending
        if similarity >= rules.threshold {
            mismatchStart = nil
            sawOwner = true
            if attentive { matches += 1 } else { heldBack = sample }
        } else {
            matches = 0
            if mismatchStart == nil { mismatchStart = time }
        }

        let identified = matches >= rules.requiredMatches
        everMatched = everMatched || identified
        needsLiveness = everMatched && (liveness == .pending || !modelSatisfied)

        if let turn = rules.challenge, !challengePassed {
            if let began = challengeStart {
                let moved = (sample.yaw - challengeBaseline) * (turn == .left ? 1 : -1)
                if moved > 0.2 {
                    challengePassed = true
                    challengePrompt = nil
                    // Must be recognised again after turning back.
                    matches = 0
                } else if time - began > 5 {
                    return .noLiveness
                }
            } else if identified, liveness == .confirmed, modelSatisfied {
                challengeStart = time
                challengeBaseline = sample.yaw
                challengePrompt = turn
            }
        }

        if matches >= rules.requiredMatches, liveness == .confirmed, modelSatisfied,
           rules.challenge == nil || challengePassed, !(rules.requiresSolitude && sample.faceCount > 1) {
            return .recognized
        }

        if !everMatched, let mismatchStart, time - mismatchStart >= rules.wrongFaceGrace { return .notRecognized }
        return timedOut ? finalOutcome : .scanning
    }

    private var finalOutcome: Outcome {
        everMatched ? .noLiveness : sawOwner ? .notAttentive : sawFace ? .notRecognized : .noFace
    }

    private mutating func forgetFace() {
        if lastBox != nil { faceChanged = true }
        lastBox = nil
        matches = 0
        everMatched = false
        needsLiveness = false
        strangerFrames = 0
        spoofScores = []
        spoofScore = nil
        challengeStart = nil
        challengePrompt = nil
        challengePassed = false
    }
}
