import CoreImage
import AVFoundation
import XCTest
@testable import FaceUnlock

final class PolicyTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func testPasswordRequiredBeforeFirstAuthentication() {
        XCTAssertEqual(UnlockPolicy().passwordRequired(at: start), .afterLaunch)
    }

    func testInactivityWindowCountsFromLock() {
        var policy = UnlockPolicy()
        policy.authenticated(at: start)
        policy.locked(at: start + 3600)
        XCTAssertNil(policy.passwordRequired(at: start + 3600 + 44 * 60))
        XCTAssertEqual(policy.passwordRequired(at: start + 3600 + 45 * 60), .timedOut)
    }

    func testStrictWindowIgnoresFaceUnlocks() {
        var policy = UnlockPolicy()
        policy.window = .strict
        policy.authenticated(at: start)
        policy.locked(at: start + 40 * 60)
        policy.faceUnlocked()
        XCTAssertEqual(policy.passwordRequired(at: start + 46 * 60), .timedOut)
    }

    func testFiveFailuresAndTypingFailureNeedPassword() {
        var policy = UnlockPolicy()
        policy.authenticated(at: start)
        for _ in 0..<5 { policy.faceRejected() }
        XCTAssertEqual(policy.passwordRequired(at: start), .tooManyAttempts)
        policy.authenticated(at: start)
        XCTAssertNil(policy.passwordRequired(at: start))
        policy.typingDidFail()
        XCTAssertEqual(policy.passwordRequired(at: start), .typingFailed)
    }
}

final class LivenessTests: XCTestCase {
    private func verdict(proof: Bool, _ frames: [LivenessFrame]) -> LivenessVerdict {
        var monitor = LivenessMonitor(requiresProof: proof)
        var verdict = LivenessVerdict.undecided
        for (index, frame) in frames.enumerated() { verdict = monitor.observe(frame, at: Double(index) * 0.05) }
        return verdict
    }

    private func still(_ count: Int) -> [LivenessFrame] {
        Array(repeating: LivenessFrame(eyeOpenness: 0.3, noseDepth: 0), count: count)
    }

    func testBlinkProvesLife() {
        let eyes: [CGFloat] = [0.30, 0.31, 0.30, 0.17, 0.12, 0.28, 0.31]
        XCTAssertEqual(verdict(proof: true, eyes.map { LivenessFrame(eyeOpenness: $0) }), .live(.blink))
    }

    func testEyesThatStayShutAreNotABlink() {
        let eyes: [CGFloat] = [0.3, 0.3, 0.3] + Array(repeating: 0.1, count: 20) + [0.3, 0.3]
        XCTAssertEqual(verdict(proof: true, eyes.map { LivenessFrame(eyeOpenness: $0) }), .undecided)
    }

    func testStillFaceNeedsProofOnlyWhenAsked() {
        XCTAssertEqual(verdict(proof: true, still(60)), .undecided)
        XCTAssertEqual(verdict(proof: false, still(2)), .undecided)
        XCTAssertEqual(verdict(proof: false, still(3)), .live(nil))
    }

    func testSpoofSignsOutweighEverything() {
        var framed = still(3)
        for index in framed.indices { framed[index].isFramed = true }
        XCTAssertEqual(verdict(proof: false, framed), .spoof(.frame))
        XCTAssertEqual(verdict(proof: false, framed + still(40)), .spoof(.frame), "it can't be waited out")
        var shiny = still(3)
        for index in shiny.indices { shiny[index].hasGlare = true }
        XCTAssertEqual(verdict(proof: true, shiny), .spoof(.glare))
    }

    /// Eyes, nose tip and mouth in centimetres, +z toward the camera, seen from `distance` away.
    private func nose(yaw degrees: Double, depth: Double, distance: Double = 45) -> CGFloat {
        let angle = degrees * .pi / 180
        func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            let turnedX = x * cos(angle) + z * sin(angle), turnedZ = z * cos(angle) - x * sin(angle)
            let scale = distance / (distance - turnedZ)
            return CGPoint(x: turnedX * scale, y: y * scale)
        }
        return NoseDepth.measure(leftEye: project(-3.15, 0, 0), rightEye: project(3.15, 0, 0),
                                 nose: project(0, -3.5, 2.8 * depth),
                                 leftMouth: project(-2.5, -7, 0.3 * depth), rightMouth: project(2.5, -7, 0.3 * depth))!
    }

    private func turning(depth: Double, to degrees: Double) -> [LivenessFrame] {
        (0..<40).map { LivenessFrame(eyeOpenness: 0.3, noseDepth: nose(yaw: degrees * sin(Double($0) / 6), depth: depth)) }
    }

    func testTurningHeadShowsDepthButAPictureDoesNot() {
        XCTAssertEqual(verdict(proof: true, turning(depth: 1, to: 9)), .live(.headTurn))
        XCTAssertEqual(verdict(proof: true, turning(depth: 0, to: 30)), .undecided)
    }

    func testAFlatPictureHeldCloseAndTiltedShowsNoDepth() {
        let measures = [-35.0, -15, 0, 15, 35].map { nose(yaw: $0, depth: 0, distance: 22) }
        XCTAssertEqual(measures.max()!, measures.min()!, accuracy: 0.001, "perspective must not look like depth")
    }

    func testTippingAPhotographIsNotABlink() {
        // Eyes and the rest of the face squash together.
        let squash: [CGFloat] = [1, 1, 1, 1, 0.5, 0.45, 1, 1, 1]
        let frames = squash.map { LivenessFrame(eyeOpenness: 0.3 * $0, faceHeight: $0) }
        XCTAssertEqual(verdict(proof: true, frames), .undecided)
    }

    func testTheOddReflectionIsNotASpoof() {
        var frames = still(40)
        for index in [8, 9, 20, 21, 30] { frames[index].hasGlare = true }
        XCTAssertEqual(verdict(proof: false, frames), .live(nil))
    }

    func testOneJumpyFrameIsNotAHeadTurn() {
        var frames = still(30)
        frames[10].noseDepth = 0.3
        frames[20].noseDepth = -0.3
        XCTAssertEqual(verdict(proof: true, frames), .undecided)
    }

    func testOnlyADeviceSizedFrameAroundTheFaceCounts() {
        let face = CGRect(x: 0.4, y: 0.35, width: 0.2, height: 0.3)
        func box(_ r: CGRect) -> [CGPoint] {
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }
        XCTAssertTrue(SpoofSigns.surrounds(box(face.insetBy(dx: -0.05, dy: -0.08)), face: face), "a phone")
        XCTAssertFalse(SpoofSigns.surrounds(box(CGRect(x: 0, y: 0, width: 1, height: 1)), face: face), "a wall")
        XCTAssertFalse(SpoofSigns.surrounds(box(face.offsetBy(dx: 0.12, dy: 0)), face: face), "a shelf cutting across")
    }

    func testGlareNeedsOneLargePatch() {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let whole = CGRect(x: 0, y: 0, width: 400, height: 400)
        let skin = CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.4)).cropped(to: whole)
        let face = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        func shine(_ side: CGFloat) -> CIImage {
            CIImage(color: .white).cropped(to: CGRect(x: 180, y: 140, width: side, height: side)).composited(over: skin)
        }
        XCTAssertFalse(SpoofSigns.hasGlare(skin, face: face, context: context))
        XCTAssertFalse(SpoofSigns.hasGlare(shine(10), face: face, context: context), "a small speck")
        XCTAssertTrue(SpoofSigns.hasGlare(shine(60), face: face, context: context))
        XCTAssertEqual(SpoofSigns.largestPatch([true, false, true, true], width: 2), 3)
    }
}

final class EnrollmentTests: XCTestCase {
    private var machine = EnrollmentMachine()
    private var time = 0.0

    @discardableResult
    private func feed(_ sample: FaceSample, seconds: Double = 1.2) -> Int {
        var captures = 0
        for _ in 0..<Int(seconds * 10) {
            if machine.process(sample, at: time) { captures += 1 }
            time += 0.1
        }
        return captures
    }

    func testFullScanCapturesSixTemplates() {
        var captures = feed(FaceSample())
        XCTAssertEqual(machine.phase, .turning)
        for sample in [FaceSample(yaw: 0.35), FaceSample(yaw: -0.35), FaceSample(pitch: 0.43), FaceSample(pitch: 0.68)] {
            captures += feed(sample, seconds: 0.6)
        }
        XCTAssertEqual(machine.phase, .lookStraight)
        captures += feed(FaceSample())
        XCTAssertEqual(machine.phase, .complete)
        XCTAssertEqual(captures, 6)
    }

    func testTurningTooFarWarnsAndCapturesNothing() {
        feed(FaceSample())
        XCTAssertEqual(feed(FaceSample(yaw: 1.1)), 0)
        XCTAssertEqual(machine.guidance, .turnedTooFar)
    }

    /// A person who barely moves their nose but clearly turns (Vision's angle) must still progress.
    func testSmallNoseShiftWithClearHeadAngleCounts() {
        feed(FaceSample(headYaw: 0, headPitch: 0))
        feed(FaceSample(yaw: 0.07, headYaw: 0.4, headPitch: 0), seconds: 0.6)
        XCTAssertEqual(machine.captured, [.left])
        feed(FaceSample(yaw: -0.07, headYaw: -0.4, headPitch: 0), seconds: 0.6)
        feed(FaceSample(pitch: 0.525, headYaw: 0, headPitch: 0.25), seconds: 0.6)
        feed(FaceSample(pitch: 0.575, headYaw: 0, headPitch: -0.25), seconds: 0.6)
        XCTAssertEqual(machine.phase, .lookStraight)
    }

    func testModestTurnsCount() {
        feed(FaceSample())
        feed(FaceSample(yaw: 0.15), seconds: 0.6)
        feed(FaceSample(pitch: 0.48), seconds: 0.6)
        XCTAssertEqual(machine.captured, [.left, .up])
    }

    func testHoldingStillCapturesNothing() {
        feed(FaceSample(headYaw: 0, headPitch: 0))
        XCTAssertEqual(feed(FaceSample(yaw: 0.02, pitch: 0.56, headYaw: 0.05, headPitch: 0.03), seconds: 3), 0)
    }

    func testWithoutHeadTurns() {
        machine = EnrollmentMachine(requiresHeadTurns: false)
        feed(FaceSample())
        feed(FaceSample())
        XCTAssertEqual(machine.phase, .complete)
    }

    func testDarkRoomDoesNotAdvance() {
        XCTAssertEqual(feed(FaceSample(brightness: 0.05)), 0)
        XCTAssertEqual(machine.guidance, .tooDark)
    }
}

final class ScannerTests: XCTestCase {
    private typealias Frame = (similarity: Float?, liveness: UnlockScanner.Liveness)
    private let box = CGRect(x: 0.4, y: 0.4, width: 0.25, height: 0.4)

    private func run(_ frames: [Frame], sample: FaceSample = FaceSample()) -> UnlockScanner.Outcome {
        var scanner = UnlockScanner()
        var outcome = UnlockScanner.Outcome.scanning
        for (index, frame) in frames.enumerated() {
            outcome = scanner.process(frame.similarity == nil ? .none : sample, box: box,
                                      similarity: frame.similarity, liveness: frame.liveness, at: Double(index) * 0.1)
            if outcome != .scanning { break }
        }
        return outcome
    }

    func testMatchWithoutAttentionIsNotCountedAsAStranger() {
        let away = FaceSample(yaw: 0.5)
        XCTAssertEqual(run(Array(repeating: (0.8, .confirmed), count: 100), sample: away), .notAttentive)
    }

    func testOwnerWithProofOfLifeUnlocks() {
        XCTAssertEqual(run([(0.8, .confirmed), (0.8, .confirmed)]), .recognized)
    }

    func testBlinkThatBreaksTheMatchStillUnlocks() {
        // Eyes closing drops similarity for a couple of frames; this used to reset everything.
        XCTAssertEqual(run([(0.8, .pending), (0.8, .pending), (0.4, .pending), (0.35, .confirmed),
                            (0.8, .confirmed), (0.8, .confirmed)]), .recognized)
    }

    func testOwnerWithoutProofOfLifeIsNotPenalised() {
        XCTAssertEqual(run(Array(repeating: (0.8, .pending), count: 100)), .noLiveness)
    }

    func testStrangerIsRejectedEvenIfLive() {
        XCTAssertEqual(run(Array(repeating: (0.3, .confirmed), count: 100)), .notRecognized)
    }

    func testSpoofOverridesAMatch() {
        XCTAssertEqual(run([(0.9, .confirmed), (0.9, .denied)]), .spoof)
    }

    func testEmptyRoom() {
        XCTAssertEqual(run(Array(repeating: (nil, .pending), count: 100)), .noFace)
    }

    func testLookingAwayDoesNotCountWithAttention() {
        XCTAssertNotEqual(run(Array(repeating: (0.9, .confirmed), count: 100), sample: FaceSample(yaw: 0.5)), .recognized)
    }

    private func scan(_ rules: UnlockScanner.Rules, yaws: [CGFloat], model: Float? = nil, faces: Int = 1) -> UnlockScanner.Outcome {
        var scanner = UnlockScanner(rules: rules)
        var outcome = UnlockScanner.Outcome.scanning
        for (index, yaw) in yaws.enumerated() {
            outcome = scanner.process(FaceSample(faceCount: faces, yaw: yaw), box: box, similarity: 0.8,
                                      liveness: .confirmed, modelScore: model, at: Double(index) * 0.1)
            if outcome != .scanning { break }
        }
        return outcome
    }

    func testChallengeNeedsTheRequestedTurn() {
        let rules = UnlockScanner.Rules(challenge: .left)
        XCTAssertEqual(scan(rules, yaws: [0, 0, 0, 0.3, 0, 0, 0]), .recognized)
        // A recording turning the other way, or not at all, never passes.
        XCTAssertEqual(scan(rules, yaws: [0, 0, -0.3] + Array(repeating: 0, count: 80)), .noLiveness)
    }

    func testSpoofModelBlocksAndPasses() {
        let rules = UnlockScanner.Rules(usesSpoofModel: true)
        XCTAssertEqual(scan(rules, yaws: Array(repeating: 0, count: 20), model: -4), .spoof)
        XCTAssertEqual(scan(rules, yaws: Array(repeating: 0, count: 20), model: 3), .recognized)
        XCTAssertEqual(scan(rules, yaws: Array(repeating: 0, count: 100), model: -0.5), .noLiveness)
    }

    func testRequiresBeingAlone() {
        XCTAssertEqual(scan(.init(requiresSolitude: true), yaws: Array(repeating: 0, count: 10), faces: 2), .notAlone)
    }

    func testSwappedFaceRestartsLiveness() {
        var scanner = UnlockScanner()
        _ = scanner.process(FaceSample(), box: box, similarity: 0.8, liveness: .confirmed, at: 0)
        _ = scanner.process(FaceSample(), box: box.offsetBy(dx: 0.35, dy: 0), similarity: 0.8, liveness: .confirmed, at: 0.1)
        XCTAssertTrue(scanner.faceChanged)
        XCTAssertEqual(scanner.matches, 1)
    }
}

final class PipelineTests: XCTestCase {
    /// Upright, unmirrored, right colours, and centred on the face: top red, bottom blue, left green.
    func testSpoofModelInputOrientation() throws {
        try XCTSkipIf(!AppModel.hasSpoofModel, "This build has no anti-spoofing model")
        let detector = try SpoofDetector()
        func block(_ colour: CIColor, _ rect: CGRect) -> CIImage { CIImage(color: colour).cropped(to: rect) }
        // Core Image's origin is bottom-left, as Vision's is.
        let picture = block(.red, CGRect(x: 0, y: 240, width: 640, height: 240))
            .composited(over: block(.blue, CGRect(x: 0, y: 0, width: 640, height: 240)))
        let marked = block(.green, CGRect(x: 200, y: 180, width: 40, height: 120)).composited(over: picture)
        let buffer = try XCTUnwrap(detector.input(marked, face: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let p = y * stride + x * 4
            return [Int(base[p + 2]), Int(base[p + 1]), Int(base[p])]
        }
        XCTAssertGreaterThan(rgb(64, 10)[0], 200, "red should be at the top")
        XCTAssertGreaterThan(rgb(64, 118)[2], 200, "blue should be at the bottom")
        // The face square spans x 176...464, so the green mark (200...240) sits on the left.
        XCTAssertGreaterThan(rgb(18, 64)[1], 100, "green should be on the left")
    }

    func testBundledSpoofModelRuns() throws {
        try XCTSkipIf(!AppModel.hasSpoofModel, "This build has no anti-spoofing model")
        let detector = try SpoofDetector()
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertNotNil(detector.score(image, face: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.5)))
    }

    func testSimilarityTransformRecoversTemplate() throws {
        let move = CGAffineTransform(translationX: 300, y: 120).rotated(by: 0.3).scaledBy(x: 4, y: 4)
        let source = FaceMath.template.map { $0.applying(move) }
        let back = try XCTUnwrap(FaceMath.similarityTransform(from: source, to: FaceMath.template))
        for (point, expected) in zip(source, FaceMath.template) {
            XCTAssertEqual(point.applying(back).x, expected.x, accuracy: 0.001)
            XCTAssertEqual(point.applying(back).y, expected.y, accuracy: 0.001)
        }
    }

    func testBundledModelProducesStableUnitVectors() throws {
        let embedder = try FaceEmbedder()
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))
        let a = try XCTUnwrap(embedder.embedding(forAligned: image))
        let b = try XCTUnwrap(embedder.embedding(forAligned: image))
        XCTAssertEqual(a.count, 128)
        XCTAssertEqual(FaceMath.similarity(a, b), 1, accuracy: 0.001)
    }

    /// A unit vector whose similarity to `axis(0)` is `similarity`; `other` picks the direction it leans.
    private func near(_ similarity: Float, other: Int = 1) -> [Float] {
        var v = [Float](repeating: 0, count: 16)
        v[0] = similarity
        v[other] = (1 - similarity * similarity).squareRoot()
        return v
    }

    private var enrolled: TemplateStore.Enrollment { .init(primary: [near(1)]) }
    private let day: TimeInterval = 24 * 60 * 60

    func testPasswordVouchesForANearMissButNotAStranger() {
        var face = enrolled
        XCTAssertFalse(face.learn(near(0.3), proof: .password, at: .now))
        XCTAssertFalse(face.learn(near(0.5), proof: .password, at: .now), "a lookalike's score")
        XCTAssertTrue(face.learn(near(0.53), proof: .password, at: .now))
        XCTAssertEqual(face.updates.count, 1)
        XCTAssertEqual(face.primary, [near(1)], "the setup scan is never altered")
    }

    func testFaceUnlockOnlyLearnsWhatTheSetupScanAccepts() {
        var face = enrolled
        XCTAssertFalse(face.learn(near(0.5), proof: .faceMatch(threshold: 0.55), at: .now))
        XCTAssertTrue(face.learn(near(0.7), proof: .faceMatch(threshold: 0.55), at: .now))
        XCTAssertFalse(face.learn(near(0.7), proof: .faceMatch(threshold: 0.55), at: .now), "nothing new")
    }

    func testUpdatesCannotDriftFromTheSetupScan() {
        var face = enrolled
        XCTAssertTrue(face.learn(near(0.55), proof: .password, at: .now))
        // Close to the update, too far from the setup scan.
        var drifted = near(0.45)
        drifted = FaceMath.normalized(drifted)
        XCTAssertGreaterThan(FaceMath.similarity(drifted, face.updates[0].vector), 0.9)
        XCTAssertFalse(face.learn(drifted, proof: .password, at: .now))
    }

    func testStalestUpdateMakesRoom() {
        var face = enrolled
        let start = Date(timeIntervalSince1970: 0)
        for index in 1...9 {
            XCTAssertTrue(face.learn(near(0.6, other: index), proof: .password,
                                     at: start.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(face.updates.count, FaceAdaptation.capacity)
        XCTAssertFalse(face.updates.contains { $0.vector == near(0.6, other: 1) })
    }

    func testUnusedAndWornOutUpdatesExpire() {
        var face = enrolled
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(face.learn(near(0.6), proof: .password, at: start))
        face.recordMatch(near(0.6), at: start.addingTimeInterval(20 * day))
        XCTAssertEqual(face.updates.first?.uses, 1)
        face.expireUpdates(at: start.addingTimeInterval(40 * day))
        XCTAssertEqual(face.updates.count, 1, "matching kept it alive")
        face.expireUpdates(at: start.addingTimeInterval(51 * day))
        XCTAssertTrue(face.updates.isEmpty)

        XCTAssertTrue(face.learn(near(0.6), proof: .password, at: start))
        for _ in 0..<FaceAdaptation.maximumUses { face.recordMatch(near(0.6), at: start) }
        face.expireUpdates(at: start)
        XCTAssertTrue(face.updates.isEmpty)
    }

    func testFaceDataSavedBeforeUpdatesStillOpens() throws {
        let old = Data(#"{"primary":[[1,0]],"alternate":[]}"#.utf8)
        let face = try JSONDecoder().decode(TemplateStore.Enrollment.self, from: old)
        XCTAssertEqual(face.primary, [[1, 0]])
        XCTAssertTrue(face.updates.isEmpty)
    }

    func testTimeLimitAndAttemptLimitCanBeChanged() {
        let start = Date(timeIntervalSince1970: 1000)
        var policy = UnlockPolicy()
        XCTAssertEqual(UnlockPolicy.timeLimits[UnlockPolicy.timeLimits.count / 2], UnlockPolicy.defaultTimeLimit)
        policy.timeout = 5 * 60
        policy.maximumFailures = 3
        policy.authenticated(at: start)
        policy.locked(at: start)
        XCTAssertNil(policy.passwordRequired(at: start + 299))
        XCTAssertEqual(policy.passwordRequired(at: start + 300), .timedOut)
        for _ in 0..<3 { policy.faceRejected() }
        XCTAssertEqual(policy.passwordRequired(at: start), .tooManyAttempts)
    }

    func testAppearancesAreStoredSeparatelyAndAllMatched() throws {
        var face = TemplateStore.Enrollment(primary: [[1, 0]])
        face[.glasses] = [[0, 1]]
        face[.hat] = [[1, 1]]
        XCTAssertEqual(face.all.count, 3)
        let reopened = try JSONDecoder().decode(TemplateStore.Enrollment.self, from: JSONEncoder().encode(face))
        XCTAssertEqual(reopened, face)
        face[.glasses] = []
        face[.hat] = []
        XCTAssertNil(face.extras)
        XCTAssertEqual(face.all, [[1, 0]])
    }

    @MainActor func testNothingStaysOnScreenAfterLeavingTheLockScreen() async throws {
        let notch = NotchPresenter()
        notch.arm {}
        let began = Date.now
        await notch.showSuccess()
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(began), 0.9, "the tick must be seen before unlocking")
        XCTAssertEqual(notch.state.phase, .success(nil))
        notch.collapse()
        notch.leaveLockScreen()
        // Long enough for any delayed callback to bring it back.
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(notch.state.phase, .closed)
        XCTAssertFalse(notch.isOnScreen)
    }

    func testEverySoundEffectIsBundled() throws {
        // The sounds are reserved and not in the repository, so builds from it have none.
        try XCTSkipIf(SoundEffect.allCases.allSatisfy { $0.url == nil }, "This build has no sound effects")
        for effect in SoundEffect.allCases {
            let url = try XCTUnwrap(effect.url, "\(effect.rawValue).wav is missing")
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertLessThan(player.duration, 4, "\(effect.rawValue) is too long for an effect")
            XCTAssertEqual(player.numberOfChannels, 2)
        }
    }

    @MainActor func testTheNotchChoosesTheSoundForWhatItShows() {
        XCTAssertEqual(NotchPresenter.sound(for: .scanning, after: .closed), .open)
        XCTAssertEqual(NotchPresenter.sound(for: .success(nil), after: .scanning), .unlock)
        XCTAssertEqual(NotchPresenter.sound(for: .failure("No"), after: .scanning), .failure)
        XCTAssertNil(NotchPresenter.sound(for: .scanning, after: .scanning))
        XCTAssertNil(NotchPresenter.sound(for: .closed, after: .success(nil)))
    }

    @MainActor func testTheNotchRestsAsAPadlockBesideTheCamera() {
        let state = NotchState()
        state.screen = .notch
        state.notch = CGSize(width: 185, height: 32)
        XCTAssertEqual(state.style, .compact, "as iPhone Duo shows it")
        state.phase = .locked
        XCTAssertFalse(state.isShut)
        XCTAssertEqual(state.size, CGSize(width: 185 + 2 * NotchState.wing, height: 36))
        state.preference = .expanded
        XCTAssertTrue(state.isShut, "the other styles stay out of sight until there is something to show")
        state.screen = .plain
        state.preference = .automatic
        XCTAssertEqual(state.style, .drop)
        XCTAssertNil(NotchPresenter.sound(for: .locked, after: .success(nil)))
    }

    @MainActor func testMessagesKeepRoomBelowAndSuccessReplacesNothing() {
        let state = NotchState()
        state.screen = .notch
        state.notch = CGSize(width: 185, height: 32)
        state.preference = .compact
        state.phase = .failure("Face Not Recognized")
        // The words' block starts 6 points under the camera and is 92 tall.
        XCTAssertGreaterThanOrEqual(state.size.height - (state.notch.height + 6 + 92), 16)
        state.phase = .scanning
        let looking = state.contentID
        state.phase = .hint("Turn Your Head Left")
        XCTAssertEqual(state.contentID, looking, "being asked to turn keeps the same face")
        state.phase = .success(nil)
        XCTAssertEqual(state.contentID, looking, "the face turns into the tick in place")
    }

    func testOnlyARealLockAndUnlockCount() {
        var screen = LockTracker()
        XCTAssertFalse(screen.unlockNotice(screenIsLocked: false), "a made-up unlock while in use")
        XCTAssertFalse(screen.lockNotice(screenIsLocked: false), "a made-up lock")
        XCTAssertFalse(screen.unlockNotice(screenIsLocked: false), "the pair, made up")
        XCTAssertTrue(screen.lockNotice(screenIsLocked: true))
        XCTAssertFalse(screen.unlockNotice(screenIsLocked: true), "a made-up unlock while locked")
        XCTAssertTrue(screen.unlockNotice(screenIsLocked: false))
        XCTAssertFalse(screen.unlockNotice(screenIsLocked: false), "twice")
    }

    func testLoweringAnyProtectionIsNoticed() {
        let normal = SecuritySettings()
        let changes: [(inout SecuritySettings) -> Void] = [
            { $0.protection = .standard }, { $0.requiresAttention = false }, { $0.timeLimit = 180 },
        ]
        for change in changes {
            var weaker = normal
            change(&weaker)
            XCTAssertTrue(weaker.isWeaker(than: normal))
            XCTAssertFalse(normal.isWeaker(than: weaker))
            XCTAssertEqual(normal.tightened(with: weaker), normal, "a tampered file can't lower anything")
        }
        var strict = normal
        strict.protection = .maximum
        strict.failureLimit = 3
        XCTAssertFalse(strict.isWeaker(than: normal))
        XCTAssertEqual(normal.tightened(with: strict), strict)
    }

    func testRecognitionIsRememberedEvenIfTheFaceThenLeaves() {
        var scanner = UnlockScanner(rules: .init(challenge: .left))
        for index in 0..<4 {
            _ = scanner.process(FaceSample(), box: nil, similarity: 0.8, liveness: .confirmed, at: Double(index) * 0.1)
        }
        for index in 4..<20 {
            _ = scanner.process(.none, box: nil, similarity: nil, liveness: .pending, at: Double(index) * 0.1)
        }
        XCTAssertTrue(scanner.reachedIdentity, "taking the recording away doesn't undo the attempt")
    }

    func testTestsNeverTouchTheRealKeychain() {
        XCTAssertEqual(Keychain.lookup("login-password"), .refused)
        XCTAssertFalse(Keychain.write(Data(), account: "login-password"))
        XCTAssertNil(PasswordVault.load())
    }
}
