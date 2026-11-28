// The moving pictures on the message cards: the face showing what to do, and an animated icon
// for each message. Each holds still on a telling moment with Reduce Motion or in a still render.

import SwiftUI

/// What the face acts out.
enum FaceCue: Equatable {
    case left, right, blinkOrTurn, lookBack

    init?(_ message: String) {
        switch message {
        case "Turn Your Head Left": self = .left
        case "Turn Your Head Right": self = .right
        case "Blink or Turn Your Head": self = .blinkOrTurn
        case "Look at the Screen": self = .lookBack
        default: return nil
        }
    }

    /// The line under the instruction while it is being asked for.
    var followUp: String { self == .blinkOrTurn ? "Keep your face in view" : "Then look back at the camera" }

    /// The moment shown when nothing may move.
    static let still = 0.6

    /// The face `t` seconds after being asked. Positive yaw faces screen left, which is the
    /// viewer's own left, as in a mirror.
    func pose(at t: Double) -> FaceGlyph.Pose {
        // A quick turn, a held pose, and back, at the pace of the setup lesson.
        func there(_ t: Double) -> CGFloat { ramp(t, 0.05, 0.35) - ramp(t, 1.35, 1.65) }
        var pose = FaceGlyph.Pose()
        switch self {
        case .left: pose.yaw = there(t.truncatingRemainder(dividingBy: 2.2))
        case .right: pose.yaw = -there(t.truncatingRemainder(dividingBy: 2.2))
        case .blinkOrTurn:
            // Two blinks, then a look to each side.
            let x = t.truncatingRemainder(dividingBy: 3.8)
            pose.blink = (x > 0.45 && x < 0.65) || (x > 0.9 && x < 1.1) ? 1 : 0
            pose.yaw = (ramp(x, 1.5, 1.8) - ramp(x, 2.3, 2.6)) - (ramp(x, 2.6, 2.9) - ramp(x, 3.4, 3.7))
        case .lookBack:
            let x = t.truncatingRemainder(dividingBy: 2.4)
            pose.yaw = 1 - ramp(x, 0.9, 1.2) + ramp(x, 2.05, 2.35)
        }
        return pose
    }
}

func ramp(_ t: Double, _ from: Double, _ to: Double) -> CGFloat {
    let x = min(max((t - from) / (to - from), 0), 1)
    return CGFloat(x * x * (3 - 2 * x))
}

/// Seconds since it appeared, or a fixed moment when nothing may move.
private struct Clock<Content: View>: View {
    var frozenAt: Double?
    var still: Double
    @ViewBuilder var content: (Double) -> Content
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if frozenAt != nil || reduceMotion {
            content(still)
        } else {
            TimelineView(.animation) { content($0.date.timeIntervalSince(start)) }
        }
    }
}

/// The white face on a refusal, acting out what went wrong.
struct RefusedFace: View {
    var message: String
    var frozenAt: Double?

    var body: some View {
        if let cue = FaceCue(message) {
            Clock(frozenAt: frozenAt, still: FaceCue.still) { FaceGlyph(pose: cue.pose(at: $0), color: .white) }
        } else {
            FaceGlyph(color: .white)
        }
    }
}

/// Someone walking out through the door.
struct WalkingIcon: View {
    var frozenAt: Double?

    var body: some View {
        Clock(frozenAt: frozenAt, still: 0.55) { t in
            Canvas { context, size in
                let s = min(size.width, size.height)
                let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
                let style = StrokeStyle(lineWidth: s * 0.085, lineCap: .round, lineJoin: .round)
                func line(_ points: [CGPoint], _ shading: GraphicsContext.Shading, in c: GraphicsContext) {
                    var path = Path()
                    path.addLines(points)
                    c.stroke(path, with: shading, style: style)
                }
                let ink = GraphicsContext.Shading.color(Theme.glow)
                // The door frame.
                line([p(0.14, 0.08), p(0.14, 0.94)], ink, in: context)

                // Across, fading as it leaves, then back at the door.
                let trip = t.truncatingRemainder(dividingBy: 2.4) / 2.4
                var walker = context
                walker.opacity = Double(min(ramp(trip, 0, 0.12), 1 - ramp(trip, 0.85, 1)))
                let x = 0.44 + 0.34 * CGFloat(trip)
                let step = sin(t * 2 * .pi / 0.8)
                let bob = CGFloat(abs(cos(t * 2 * .pi / 0.8))) * 0.025
                let hip = p(x, 0.58 - bob), shoulder = p(x + 0.04, 0.33 - bob)
                walker.fill(Path(ellipseIn: CGRect(x: p(x + 0.07, 0).x - s * 0.085, y: p(0, 0.07 - bob).y,
                                                   width: s * 0.17, height: s * 0.17)), with: ink)
                line([shoulder, hip], ink, in: walker)
                func limb(from: CGPoint, angle: CGFloat, bend: CGFloat, length: CGFloat) {
                    let middle = CGPoint(x: from.x + sin(angle) * length * s, y: from.y + cos(angle) * length * s)
                    let end = CGPoint(x: middle.x + sin(angle + bend) * length * s, y: middle.y + cos(angle + bend) * length * s)
                    line([from, middle, end], ink, in: walker)
                }
                for side in [1.0, -1.0] {
                    let swing = CGFloat(step * side)
                    limb(from: hip, angle: swing * 0.6, bend: -0.25 - max(-swing, 0) * 0.5, length: 0.18)
                    limb(from: shoulder, angle: -swing * 0.7, bend: 0.7, length: 0.13)
                }
            }
        }
        .accessibilityLabel("Walking away")
    }
}

/// A padlock whose shackle lifts and snaps shut.
struct LockIcon: View {
    var colour: Color
    var frozenAt: Double?

    var body: some View {
        Clock(frozenAt: frozenAt, still: 0.4) { t in
            let x = t.truncatingRemainder(dividingBy: 2.4)
            let lift = ramp(x, 1.0, 1.3) - ramp(x, 1.75, 1.9)
            let snap = x > 1.9 && x < 2.2 ? sin((x - 1.9) * 2 * .pi * 10) * (2.2 - x) * 12 : 0
            Canvas { context, size in
                let s = min(size.width, size.height)
                let left = (size.width - s) / 2, top = (size.height - s) / 2
                let rise = lift * s * 0.08
                var shackle = Path()
                shackle.move(to: CGPoint(x: left + s * 0.33, y: top + s * 0.52 - rise))
                shackle.addLine(to: CGPoint(x: left + s * 0.33, y: top + s * 0.31 - rise))
                shackle.addArc(center: CGPoint(x: left + s * 0.5, y: top + s * 0.31 - rise), radius: s * 0.17,
                               startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                shackle.addLine(to: CGPoint(x: left + s * 0.67, y: top + s * 0.52 - rise * 0.2))
                context.stroke(shackle, with: .color(colour), style: StrokeStyle(lineWidth: s * 0.09, lineCap: .round))
                context.fill(Path(roundedRect: CGRect(x: left + s * 0.2, y: top + s * 0.50, width: s * 0.6, height: s * 0.44),
                                  cornerRadius: s * 0.1, style: .continuous), with: .color(colour))
            }
            .offset(x: snap)
        }
        .accessibilityLabel("Locked")
    }
}

/// A key giving a turn, as in a lock.
struct KeyIcon: View {
    var frozenAt: Double?

    var body: some View {
        Clock(frozenAt: frozenAt, still: 0) { t in
            let x = t.truncatingRemainder(dividingBy: 2.2)
            let turn = ramp(x, 0.4, 0.8) - ramp(x, 1.35, 1.75)
            Image(systemName: "key.fill")
                .resizable().scaledToFit().padding(.vertical, 4)
                .foregroundStyle(Theme.glow)
                .rotation3DEffect(.degrees(Double(turn) * 70), axis: (x: 0, y: 1, z: 0))
                .rotationEffect(.degrees(Double(turn) * -35))
        }
        .accessibilityLabel("Key")
    }
}

/// Someone who wasn't recognised, with a warning that pops.
struct AttemptsIcon: View {
    var frozenAt: Double?

    var body: some View {
        Clock(frozenAt: frozenAt, still: 1.2) { t in
            let x = t.truncatingRemainder(dividingBy: 2.2)
            let shake = x < 0.5 ? sin(x * 2 * .pi * 6) * (0.5 - x) * 10 : 0
            let pop = 1 + 0.3 * max(0, sin((x - 0.5) / 0.4 * .pi)) * (x > 0.5 && x < 0.9 ? 1 : 0)
            GeometryReader { space in
                let s = min(space.size.width, space.size.height)
                ZStack(alignment: .bottomLeading) {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(Theme.glow)
                        .frame(width: s * 0.86, height: s * 0.86).offset(x: s * 0.14, y: -s * 0.1)
                    Image(systemName: "exclamationmark.circle.fill").resizable()
                        .symbolRenderingMode(.palette).foregroundStyle(.black, .white)
                        .frame(width: s * 0.42, height: s * 0.42)
                        .background(Circle().fill(.black).padding(-3))
                        .scaleEffect(pop)
                }
                .frame(width: s, height: s)
                .offset(x: shake)
                .frame(width: space.size.width, height: space.size.height)
            }
        }
        .accessibilityLabel("Unrecognized attempt")
    }
}

/// The icon for a notice, by the symbol the app asks for.
struct NoticeIcon: View {
    var symbol: String
    var frozenAt: Double?

    var body: some View {
        Group {
            switch symbol {
            case "figure.walk.departure": WalkingIcon(frozenAt: frozenAt)
            case "person.crop.circle.badge.exclamationmark": AttemptsIcon(frozenAt: frozenAt)
            case "key.fill": KeyIcon(frozenAt: frozenAt)
            case "lock.fill": LockIcon(colour: Theme.glow, frozenAt: frozenAt)
            default: Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(Theme.glow)
            }
        }
        // As much of the room as the face fills, so each card has the same space around it.
        .padding(1)
        .scaleEffect(0.87)
    }
}
