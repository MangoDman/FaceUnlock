import CoreGraphics
import Foundation

/// What one camera frame says about the face in front of the Mac. Pure data, so the
/// state machines below can be tested without a camera.
struct FaceSample: Equatable {
    var faceCount = 1
    /// Face centre relative to frame centre, in units of frame height.
    var offset = CGSize.zero
    /// Face height / frame height.
    var size: CGFloat = 0.4
    /// Nose offset from the eye midpoint / eye distance. Positive = head turned to the user's left.
    var yaw: CGFloat = 0
    /// Nose height between eyes (0) and mouth (1). Smaller = looking up.
    var pitch: CGFloat = 0.55
    /// Eye height / width, averaged over both eyes.
    var eyeOpenness: CGFloat = 0.3
    /// Mean luminance, 0...1.
    var brightness: CGFloat = 0.5
    /// Vision's own head angles in radians. Only their size is used; the direction comes from
    /// `yaw` and `pitch`, whose signs follow directly from where the nose moves.
    var headYaw: CGFloat?
    var headPitch: CGFloat?

    static let none = FaceSample(faceCount: 0)

    var isTooDark: Bool { brightness < 0.16 }
    var isCentred: Bool { abs(offset.width) < 0.22 && abs(offset.height) < 0.2 }
    /// Looking at the Mac with eyes open, closely enough to unlock it. Wider than
    /// `isFacingScreen`, which setup uses to take its straight-on picture.
    var isAttending: Bool { abs(yaw) < 0.3 && pitch > 0.25 && pitch < 0.85 && eyeOpenness > 0.12 }
    /// Roughly facing the screen.
    var isFacingScreen: Bool { abs(yaw) < 0.22 && pitch > 0.3 && pitch < 0.8 }
}
