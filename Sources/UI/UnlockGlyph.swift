import SwiftUI

/// The notch's face while it looks for you, and its turn into a tick, as one drawing. Nothing
/// is swapped out: the four outer arcs spin and grow until they meet, the head's circle swells
/// out to join them, the features fade, and the tick draws in the middle of the single ring.
struct UnlockGlyph: View {
    var success: Bool
    var frozenAt: Double?
    /// What the face is asking you to do, which it acts out.
    var cue: FaceCue?
    @State private var asked: (cue: FaceCue, at: Date)?
    /// Where the face was when you were recognised, to ease back from.
    @State private var heldPose = FaceGlyph.Pose()
    @State private var start = Date.now
    /// Seconds into the success, carried by SwiftUI's own animation.
    @State private var since = 0.0
    /// Where the looking pulse was when you were recognised, so nothing jumps.
    @State private var held = 0.26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the moments fall, in seconds from recognition. The unlock sound and haptics are
    /// composed to the same beats (`Tools/make_sounds.py`).
    enum Beat {
        static let spin = 0.70
        static let joined = 0.60
        static let tickStart = 0.62
        static let tickEnd = 1.05
    }

    /// The finished ring's radius and stroke, as shares of the drawing's size.
    static let ringRadius: CGFloat = 0.364
    static let ringWidth: CGFloat = 0.071

    var body: some View {
        // One structure for looking and recognised, so nothing is exchanged mid-way.
        TimelineView(.animation(paused: success)) { timeline in
            let looking = frozenAt ?? (reduceMotion ? 0.26 : success ? held : timeline.date.timeIntervalSince(start))
            var pose = heldPose
            if !success {
                pose = FaceGlyph.Pose()
                if frozenAt != nil || reduceMotion {
                    pose = cue?.pose(at: FaceCue.still) ?? pose
                } else if let asked {
                    pose = asked.cue.pose(at: timeline.date.timeIntervalSince(asked.at))
                }
            }
            return Drawing(looking: looking, since: !success ? -1 : frozenAt != nil || reduceMotion ? 10 : since, pose: pose)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(success ? "Recognized" : "Looking for you")
        .onChange(of: cue, initial: true) { _, new in
            if let new { asked = (new, .now) } else if !success { asked = nil }
        }
        .onChange(of: success, initial: true) { _, done in
            since = 0
            guard done else { return }
            held = Date.now.timeIntervalSince(start)
            heldPose = asked.map { $0.cue.pose(at: Date.now.timeIntervalSince($0.at)) } ?? FaceGlyph.Pose()
            withAnimation(.linear(duration: Beat.tickEnd * Theme.slowMotion)) { since = Beat.tickEnd }
        }
    }

    /// Redrawn for every step of the animation. A negative `since` means still looking.
    private struct Drawing: View, Animatable {
        var looking: Double
        var since: Double
        var pose = FaceGlyph.Pose()
        var animatableData: Double {
            get { since }
            set { since = newValue }
        }

        var body: some View {
            Canvas { context, size in
                UnlockGlyph.draw(&context, size: size, looking: looking, since: since < 0 ? nil : since, pose: pose)
            }
        }
    }

    private static func ease(_ t: Double, _ from: Double, _ to: Double) -> CGFloat {
        let x = min(max((t - from) / (to - from), 0), 1)
        return CGFloat(x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2)
    }

    /// An even movement with soft ends, so the middle isn't over in an instant.
    private static func glide(_ t: Double, _ from: Double, _ to: Double) -> CGFloat {
        let x = min(max((t - from) / (to - from), 0), 1)
        return CGFloat(0.5 - 0.5 * cos(.pi * x))
    }

    /// `since` is nil while still looking.
    static func draw(_ context: inout GraphicsContext, size: CGSize, looking: Double, since: Double?,
                     pose turned: FaceGlyph.Pose = .init()) {
        let s = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

        // The looking pulse: a period of 1.035 s, eyes and smile out of step with the ring.
        let phase = looking / 1.035 * 2 * .pi
        let ring = 0.5 - 0.5 * cos(phase)
        let glint = 0.5 - 0.5 * cos(phase + 2.4)

        let t = since ?? -1
        let settle = ease(t, 0, 0.25)
        // A turned head comes back to face you as it is recognised.
        let yaw = turned.yaw * (1 - settle)
        // A gentle turn the whole way; the arcs stay apart while they spin, then close.
        let spin = glide(t, 0, Beat.spin)
        let draw = glide(t, 0, Beat.joined)
        let close = ease(t, 0.34, Beat.joined)
        let swell = ease(t, 0.30, Beat.joined)
        let tick = ease(t, Beat.tickStart, Beat.tickEnd)

        let ringColor = Theme.deep.mix(with: Theme.glow, by: mix(ring, 1, settle))
        let finalRadius = s * ringRadius, finalWidth = s * ringWidth

        // Four arcs: spin three quarters of a turn while their ends reach for each other.
        let restingRadius = s * (0.445 + 0.012 * 0.3 + ring * 0.018 - 0.008)
        let arcRadius = mix(restingRadius, finalRadius, draw)
        let half = mix(31, 45.6, close)
        for quarter in 0..<4 {
            let middle = Double(quarter) * 90 - 90 + Double(spin) * 360
            var arc = Path()
            arc.addArc(center: c, radius: arcRadius, startAngle: .degrees(middle - half),
                       endAngle: .degrees(middle + half), clockwise: false)
            // The arc on the side being turned to lights up and thickens. (1 is right, 3 left.)
            let lit = since == nil ? min(max(quarter == 3 ? yaw : quarter == 1 ? -yaw : 0, 0), 1) : 0
            context.stroke(arc, with: .color(lit > 0.5 ? Theme.glow : ringColor.opacity(mix(0.685, 1, draw))),
                           style: StrokeStyle(lineWidth: mix(s * 0.0288 * (1.12 + 0.9 * lit), finalWidth, draw), lineCap: .round))
        }

        // The head's circle swells out to meet them.
        let headRadius = mix(s * 0.3236, finalRadius, swell)
        context.stroke(Path(ellipseIn: CGRect(x: c.x - headRadius, y: c.y - headRadius,
                                              width: headRadius * 2, height: headRadius * 2)),
                       with: .color(ringColor), lineWidth: mix(s * 0.0422, finalWidth, swell))

        // Eyes, nose and smile fade as the ring takes over.
        let fade = 1 - ease(t, 0, 0.28)
        if fade > 0 {
            var face = context
            face.opacity = fade
            face.translateBy(x: c.x, y: c.y)
            face.scaleBy(x: mix(0.7, 1, fade), y: mix(0.7, 1, fade))
            face.translateBy(x: -c.x, y: -c.y)
            var pose = FaceGlyph.Pose()
            pose.yaw = yaw
            pose.blink = turned.blink
            pose.ringOpacity = 0
            pose.arcs = [-1, -1, -1, -1]
            FaceGlyph.draw(&face, size: size, pose: pose, color: Theme.deep.mix(with: Theme.glow, by: glint))
        }

        // The tick, in the square the ring encloses.
        if tick > 0 {
            let box = CGRect(x: c.x - finalRadius, y: c.y - finalRadius, width: finalRadius * 2, height: finalRadius * 2)
            context.stroke(Checkmark().path(in: box).trimmedPath(from: 0, to: tick), with: .color(Theme.glow),
                           style: StrokeStyle(lineWidth: s * 0.078, lineCap: .round, lineJoin: .round))
        }
    }
}
