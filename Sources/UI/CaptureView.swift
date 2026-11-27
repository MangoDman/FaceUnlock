import AVFoundation
import SwiftUI

/// Mirrored live camera. The flip is applied to the layer itself: setting it on the capture
/// connection fails silently when the session isn't configured yet, which left the picture
/// reversed.
final class MirroredPreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer = CALayer()
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.setAffineTransform(.identity)
        preview.bounds = CGRect(origin: .zero, size: bounds.size)
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        CATransaction.commit()
    }

    var isBlurred = false {
        didSet {
            preview.filters = isBlurred ? CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 14]).map { [$0] } : nil
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var blurred = false

    func makeNSView(context: Context) -> MirroredPreviewView { MirroredPreviewView(session: session) }

    func updateNSView(_ view: MirroredPreviewView, context: Context) {
        // The connection may only appear after the view; never let it mirror a second time.
        if let connection = view.preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        view.isBlurred = blurred
        view.needsLayout = true
    }
}

enum CaptureStyle: String, CaseIterable, Identifiable {
    /// Four arcs, as on iPhone Duo.
    case arcs
    /// A ring of ticks, as in Face ID setup.
    case ticks
    var id: String { rawValue }
}

private struct OutsideCircle: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        return p
    }
}

/// How strongly the head currently points at a direction, 0...1.
private func pull(_ turn: CGVector, toward direction: EnrollmentMachine.Direction) -> Double {
    let amount: CGFloat = switch direction {
    case .up: -turn.dy
    case .down: turn.dy
    case .left: -turn.dx
    case .right: turn.dx
    }
    return Double(min(max(amount, 0), 1))
}

/// A soft band of light drifting toward the direction still needed. The motion is the cue, not an arrow.
private struct DirectionSweep: View {
    var direction: EnrollmentMachine.Direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let eased = 1 - pow(1 - t, 3)
                let travel = CGFloat(eased - 0.5) * 360
                let horizontal = direction == .left || direction == .right
                let sign: CGFloat = direction == .left || direction == .up ? -1 : 1
                Ellipse()
                    .fill(Theme.glow)
                    .frame(width: horizontal ? 70 : 280, height: horizontal ? 280 : 70)
                    .blur(radius: 34)
                    .offset(x: horizontal ? travel * sign : 0, y: horizontal ? 0 : travel * sign)
                    .opacity(0.45 * sin(.pi * t))
                    .blendMode(.screen)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Camera card with the guide, and the completion animation:
/// segments close into a ring → ring shrinks while the picture dims → checkmark draws.
struct CaptureCard<Feed: View>: View {
    var captured: Set<EnrollmentMachine.Direction>
    var lookingStraight: Bool
    var complete: Bool
    var turn = CGVector.zero
    var hint: EnrollmentMachine.Direction?
    var style = CaptureStyle.arcs
    @ViewBuilder var feed: Feed

    @State private var closed = false
    @State private var shrunk = false
    @State private var checked = false
    @State private var pulse = false

    private let side: CGFloat = 320

    var body: some View {
        ZStack {
            feed.overlay(Color.black.opacity(shrunk ? 0.45 : 0))
            OutsideCircle(radius: side * 0.38)
                .fill(.black.opacity(complete ? 0 : 0.45), style: FillStyle(eoFill: true))
            if let hint, !complete, !lookingStraight {
                DirectionSweep(direction: hint)
            }

            ZStack {
                switch style {
                case .arcs: arcs
                case .ticks: ticks
                }
                Checkmark()
                    .trim(from: 0, to: checked ? 1 : 0)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }
            .frame(width: side * (shrunk ? 0.42 : 0.78), height: side * (shrunk ? 0.42 : 0.78))
            .scaleEffect(pulse ? 1.035 : 1)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onChange(of: captured.count) { old, new in
            guard new > old else { return }
            withAnimation(.easeOut(duration: 0.14)) { pulse = true }
            withAnimation(Theme.open.delay(0.14)) { pulse = false }
        }
        .onChange(of: complete, initial: true) { _, done in
            guard done else {
                closed = false
                shrunk = false
                checked = false
                return
            }
            withAnimation(.easeInOut(duration: 0.3)) { closed = true }
            withAnimation(.spring(duration: 0.4).delay(0.3)) { shrunk = true }
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.35).delay(0.65)) { checked = true }
        }
    }

    private func isLit(_ direction: EnrollmentMachine.Direction) -> Bool {
        captured.contains(direction) || lookingStraight || complete
    }

    private var arcs: some View {
        ForEach(Array(EnrollmentMachine.Direction.allCases.enumerated()), id: \.offset) { index, direction in
            let lit = isLit(direction)
            let leaning = pull(turn, toward: direction)
            // .up is at 12 o'clock; angles start at 3 o'clock.
            let centre = Double(index) * 90 - 90
            let half = closed ? 45.2 : 36.0
            Arc(start: .degrees(centre - half), end: .degrees(centre + half))
                .stroke(lit ? Theme.accent : Color.white.mix(with: Theme.accent, by: leaning).opacity(0.35 + 0.65 * leaning),
                        style: StrokeStyle(lineWidth: lit ? 9 : 5 + 3 * leaning, lineCap: .round))
                .animation(Theme.open, value: lit)
                .animation(.easeOut(duration: 0.15), value: leaning)
        }
    }

    private var ticks: some View {
        let count = 72
        let radius = side * (shrunk ? 0.21 : 0.39)
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                let angle = Double(index) * 360 / Double(count)
                let direction = EnrollmentMachine.Direction.allCases[Int((angle + 45) / 90) % 4]
                let lit = isLit(direction)
                let leaning = lit ? 0 : pull(turn, toward: direction)
                let length: CGFloat = lit ? 18 : 10 + 5 * leaning
                Capsule()
                    .fill(lit ? Theme.accent : Color.white.mix(with: Theme.accent, by: leaning).opacity(0.5 + 0.5 * leaning))
                    .frame(width: 2.6, height: length)
                    .offset(y: -(radius + length / 2 - 6))
                    .rotationEffect(.degrees(angle))
                    // A captured quarter fills as a sweep rather than all at once.
                    .animation(.easeOut(duration: 0.3).delay(Double(index % 18) * 0.008), value: lit)
            }
            .opacity(closed ? 0 : 1)
            Circle().stroke(Theme.accent, lineWidth: 9)
                .opacity(closed ? 1 : 0)
        }
    }
}

struct Arc: Shape {
    var start: Angle
    var end: Angle

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start.degrees, end.degrees) }
        set {
            start = .degrees(newValue.first)
            end = .degrees(newValue.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: start, endAngle: end, clockwise: false)
        return p
    }
}
