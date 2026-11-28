import SwiftUI

/// The face-and-four-arcs mark, drawn from the iOS 27.3 beta footage. Everything is relative to
/// the view size, so one drawing serves the instructions, the notch and the app icon.
struct FaceGlyph: View {
    struct Pose: Equatable {
        /// -1...1: positive turns the face toward the viewer's left.
        var yaw: CGFloat = 0
        /// -1...1: positive looks up.
        var pitch: CGFloat = 0
        /// 0 open, 1 closed.
        var blink: CGFloat = 0
        /// Per arc (up, right, down, left): 0 resting, 1 captured.
        var arcs: [CGFloat] = [0, 0, 0, 0]
        var arcSpread: CGFloat = 0
        var ringOpacity: Double = 1
        var featureOpacity: Double = 1
    }

    var pose = Pose()
    var color: Color = .white

    var body: some View {
        Canvas { context, size in Self.draw(&context, size: size, pose: pose, color: color) }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("Face")
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize, pose: Pose, color: Color) {
            let s = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)

            // The app's mark, in fractions of its size: the same numbers as the icon and website.
            // Four arcs, clockwise from the top.
            for (index, centre) in [-90.0, 0, 90, 180].enumerated() {
                let lit = pose.arcs[index]
                guard lit >= 0 else { continue }
                let radius = s * (0.445 + 0.012 * lit + pose.arcSpread)
                var arc = Path()
                arc.addArc(center: c, radius: radius, startAngle: .degrees(centre - 31),
                           endAngle: .degrees(centre + 31), clockwise: false)
                context.stroke(arc, with: .color(color.opacity(0.55 + 0.45 * Double(lit))),
                               style: StrokeStyle(lineWidth: s * 0.0288 * (1 + 0.75 * lit), lineCap: .round))
            }

            // The head stays round and still; only what is on it moves.
            let radius = s * 0.3236
            let head = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: head), with: .color(color.opacity(pose.ringOpacity)), lineWidth: s * 0.0422)

            // Features slide toward the side the head faces. The nose stands out from the face,
            // so it travels about twice as far as the eyes and mouth: that is what reads as a turn.
            let shift = CGPoint(x: c.x - pose.yaw * s * 0.058, y: c.y - pose.pitch * s * 0.052)
            let proud = CGPoint(x: -pose.yaw * s * 0.052, y: -pose.pitch * s * 0.045)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: shift.x + x * s, y: shift.y + y * s) }
            func tip(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: point(x, y).x + proud.x, y: point(x, y).y + proud.y) }
            let ink = GraphicsContext.Shading.color(color.opacity(pose.featureOpacity))
            func draw(_ path: Path, _ weight: CGFloat) {
                context.stroke(path, with: ink, style: StrokeStyle(lineWidth: s * weight, lineCap: .round, lineJoin: .round))
            }
            var eyes = Path()
            for x in [-0.1283, 0.1283] {
                if pose.blink > 0.8 {
                    eyes.move(to: point(x - 0.025, -0.0765))
                    eyes.addLine(to: point(x + 0.025, -0.0765))
                } else {
                    let half = 0.0259 * (1 - pose.blink)
                    eyes.move(to: point(x, -0.0765 - half))
                    eyes.addLine(to: point(x, -0.0765 + half))
                }
            }
            draw(eyes, 0.0469)
            // Hooked nose.
            var nose = Path()
            nose.move(to: tip(0.0084, -0.0999))
            nose.addLine(to: tip(0.0084, 0.0025))
            nose.addQuadCurve(to: tip(-0.0173, 0.0281), control: tip(0.0084, 0.0281))
            nose.addLine(to: tip(-0.0291, 0.0281))
            draw(nose, 0.0414)
            var smile = Path()
            smile.move(to: point(-0.0952, 0.1021))
            smile.addQuadCurve(to: point(0.0952, 0.1021), control: point(0, 0.188))
            draw(smile, 0.0412)
    }
}

private func smooth(_ t: Double, _ from: Double, _ to: Double) -> CGFloat {
    let x = min(max((t - from) / (to - from), 0), 1)
    return CGFloat(x * x * (3 - 2 * x))
}

/// The looping "how to move your head" lesson: left, right, up, down, blink (10.5 s).
struct InstructionGlyph: View {
    var color: Color = .primary
    var frozenAt: Double?
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func pose(at t: Double) -> FaceGlyph.Pose {
        func swing(_ from: Double, _ to: Double) -> CGFloat {
            smooth(t, from, from + 0.45) - smooth(t, to - 0.45, to)
        }
        var pose = FaceGlyph.Pose()
        pose.yaw = swing(0.6, 2.3) - swing(2.4, 4.1)
        pose.pitch = swing(4.4, 5.9) - swing(6.0, 7.5)
        // Arc order: up, right, down, left. Each stays lit once reached.
        pose.arcs = [smooth(t, 4.7, 5.0), smooth(t, 2.8, 3.1), smooth(t, 6.3, 6.6), smooth(t, 1.0, 1.3)]
        pose.blink = swing(7.7, 8.4) > 0.5 ? 1 : 0
        return pose
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = frozenAt ?? (reduceMotion ? 10 : timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 10.5))
            FaceGlyph(pose: Self.pose(at: t), color: color)
        }
    }
}

struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.53))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.34))
        return p
    }
}
