// FaceUnlock's presence at the top of the screen, for the three kinds of Mac display:
//  - a notch: the whole notch grows downward;
//  - a Dynamic Island (2026 touch MacBook Pro): the island grows into a card;
//  - neither (Intel, M1 Air, 13-inch Pro, external displays): a pill drops from the top edge.
// "Pill" and "Compact" can also be chosen by hand. The face animation is iPhone Duo's.
//
// Everything moves only downward: content is laid out at its final width from the start, so
// nothing can drift sideways while its container grows.

import AppKit
import SwiftUI

/// What sits at the top of a display.
enum ScreenKind: String, CaseIterable, Identifiable {
    case notch, island, plain
    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: "Notch"
        case .island: "Dynamic Island"
        case .plain: "No Notch"
        }
    }

    /// There's no island API, but macOS 27 reports touch, and the island MacBook Pro is the only
    /// MacBook with a touch display. Every screen with neither reports no safe-area inset.
    static func of(_ screen: NSScreen) -> ScreenKind {
        if #available(macOS 27.0, *), CGDisplayIsBuiltin(screen.displayID) != 0,
           screen.touchCapabilities.contains(.multiTouch) {
            return .island
        }
        return screen.safeAreaInsets.top > 0 ? .notch : .plain
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// The words the three views share.
private enum Words {
    static let retry = "Point here to try again"
    static let password = "Use Touch ID or type your password"
}

/// The measurements the three views share, so a state is laid out alike in each.
enum FaceLayout {
    /// The face while it is the whole of the Notch's panel, and in the Pill's circle.
    static let notch: CGFloat = 96, pill: CGFloat = 100
    /// The face (or padlock) above a message in the Pill and Compact.
    static let card: CGFloat = 76
    /// Beside the camera in Compact, which is only as tall as the notch.
    static let wing: CGFloat = 27
    static let gap: CGFloat = 6
}

@MainActor @Observable
final class NotchState {
    /// What the user picked in Settings.
    enum Preference: String, CaseIterable, Identifiable {
        case automatic, expanded, drop, compact
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .expanded: "Expanding Notch"
            case .drop: "Drop Pill"
            case .compact: "Compact"
            }
        }
    }

    enum Style: Equatable { case expanded, island, drop, compact }

    enum Phase: Hashable {
        /// Exactly the size of the hardware notch, so it can't be seen.
        case closed
        /// Waiting at the lock screen. The compact style shows a padlock, as iPhone Duo does;
        /// the others look closed.
        case locked
        case scanning
        case hint(String)
        case success(String?)
        case failure(String)
        case passwordRequired
        /// Information that needs no answer.
        case notice(symbol: String, title: String, message: String)
        /// Needs a decision; shown only while unlocked.
        case prompt(title: String, message: String)

        var announcement: String? {
            switch self {
            case .closed, .locked, .scanning: nil
            case .hint(let text), .failure(let text): text
            case .success(let text): text ?? "Face recognized"
            case .passwordRequired: "Password required"
            case .prompt(let title, let message): "\(title). \(message)"
            case .notice(_, let title, let message): "\(title). \(message)"
            }
        }
    }

    var phase = Phase.closed
    var preference = Preference.automatic
    var screen = ScreenKind.notch
    /// The notch or island itself. Empty height on a plain screen.
    var notch = CGSize(width: 190, height: 32)
    /// Space between the screen edge and the island.
    var topInset: CGFloat = 0
    var hovering = false
    var onHover: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onDismiss: (() -> Void)?

    var style: Style {
        switch preference {
        case .automatic: screen == .plain ? .drop : .compact
        case .expanded: screen == .island ? .island : screen == .plain ? .drop : .expanded
        case .drop: .drop
        case .compact: .compact
        }
    }

    /// Where the pill is, measured from the top of the screen.
    struct Drop: Equatable {
        var top: CGFloat
        var width: CGFloat
        var height: CGFloat
        var radius: CGFloat
    }

    var drop: Drop {
        // Far enough below a notch or island to break away from it completely.
        let rest = screen == .plain ? 10 : topInset + notch.height + 16
        return switch phase {
        case .closed, .locked:
            switch screen {
            case .notch: Drop(top: max(notch.height - 22, 0), width: 40, height: 18, radius: 9)
            case .island: Drop(top: topInset + 2, width: 36, height: 18, radius: 9)
            // Waiting just above the screen.
            case .plain: Drop(top: -70, width: 60, height: 60, radius: 30)
            }
        case .scanning, .success(nil): Drop(top: rest, width: 120, height: 120, radius: 60)
        case .hint: Drop(top: rest, width: 260, height: 164, radius: 38)
        case .success, .failure, .passwordRequired: Drop(top: rest, width: 260, height: 147, radius: 38)
        case .notice: Drop(top: rest, width: 300, height: 147, radius: 38)
        case .prompt: Drop(top: rest, width: 340, height: 209, radius: 38)
        }
    }

    /// Room each side of the camera in the compact style.
    static let wing: CGFloat = 56

    var isCompactView: Bool {
        guard style == .compact else { return false }
        return switch phase {
        case .locked, .scanning, .success(nil): true
        default: false
        }
    }

    /// Looking, being asked to turn, and recognised are one piece of content, so the face
    /// stays where it is and turns into the tick without anything being replaced.
    var contentID: Phase {
        switch phase {
        case .locked, .success(nil), .hint: .scanning
        default: phase
        }
    }

    /// What the face should be acting out.
    var cue: FaceCue? {
        if case .hint(let text) = phase { FaceCue(text) } else { nil }
    }

    var isSuccess: Bool {
        if case .success = phase { true } else { false }
    }

    /// Nothing is showing beyond the hardware itself.
    var isShut: Bool { phase == .closed || (phase == .locked && style != .compact) }

    /// The visible area below `topGap`, used for drawing and for the pointer.
    var size: CGSize {
        if isShut { return notch }
        switch style {
        case .drop:
            return CGSize(width: drop.width, height: drop.top + drop.height)
        case .expanded, .island:
            let narrow = max(notch.width + 40, 236), wide = max(notch.width + 40, 346)
            return switch phase {
            case .notice: CGSize(width: wide, height: notch.height + 147)
            case .prompt: CGSize(width: wide, height: notch.height + 207)
            // Two lines of words under the face need a little more.
            case .hint, .failure, .passwordRequired: CGSize(width: narrow, height: notch.height + 168)
            default: CGSize(width: narrow, height: notch.height + 152)
            }
        case .compact:
            let wide = max(notch.width + 2 * Self.wing, 344)
            return switch phase {
            case .closed: notch
            case .locked, .scanning, .success(nil): CGSize(width: notch.width + 2 * Self.wing, height: max(notch.height, 36))
            case .hint: CGSize(width: wide, height: max(notch.height, 36) + 54)
            // One line of words rather than two.
            case .success: CGSize(width: wide, height: notch.height + 131)
            case .failure, .passwordRequired, .notice: CGSize(width: wide, height: notch.height + 147)
            case .prompt: CGSize(width: wide, height: notch.height + 207)
            }
        }
    }

    /// Corner radius of the grown shapes.
    var radius: CGFloat {
        if isShut { return screen == .notch ? 11 : notch.height / 2 }
        return switch style {
        case .expanded, .island: 38
        default: isCompactView ? 18 : 38
        }
    }

    /// The concave corners that flare the expanded notch into the screen edge.
    var flare: CGFloat {
        guard !isShut, !floating else { return 0 }
        return switch style {
        case .expanded: 16
        // Smaller on the bar, which is only as deep as the notch.
        case .compact: isCompactView ? 8 : 16
        default: 0
        }
    }

    /// Whether the shape floats with all four corners rounded.
    var floating: Bool { style == .island || (style == .compact && screen != .notch) }

    /// Gap above a floating shape.
    var topGap: CGFloat {
        switch style {
        case .island: topInset
        case .compact: screen == .island ? topInset : screen == .plain ? 6 : 0
        default: 0
        }
    }
}

/// Square (or flared) at the screen edge, rounded below; rounded all round when `floating`.
struct IslandShape: Shape {
    var radius: CGFloat
    var flare: CGFloat
    var floating: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, flare) }
        set {
            radius = newValue.first
            flare = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        if floating {
            return Path(roundedRect: rect, cornerRadius: min(radius, rect.height / 2), style: .continuous)
        }
        let r = max(0, min(radius, rect.height - flare, rect.width / 2 - flare))
        // The body is inset by the flare, which sweeps outward along the top edge.
        let left = rect.minX + flare, right = rect.maxX - flare
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + flare), control: CGPoint(x: left, y: rect.minY))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        p.addCurve(to: CGPoint(x: left + r, y: rect.maxY),
                   control1: CGPoint(x: left, y: rect.maxY - r * 0.36), control2: CGPoint(x: left + r * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: right, y: rect.maxY - r),
                   control1: CGPoint(x: right - r * 0.36, y: rect.maxY), control2: CGPoint(x: right, y: rect.maxY - r * 0.36))
        p.addLine(to: CGPoint(x: right, y: rect.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The pill and whatever it leaves, blurred together and thresholded: they cling while close,
/// then snap apart. Nothing joins them once the pill has arrived.
private struct Liquid: View, Animatable {
    /// The notch, island or (off screen) top edge the pill comes from.
    var source: CGRect
    var sourceRadius: CGFloat
    var dropTop: CGFloat
    var dropWidth: CGFloat
    var dropHeight: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(dropTop, dropWidth), AnimatablePair(dropHeight, radius)) }
        set {
            dropTop = newValue.first.first
            dropWidth = newValue.first.second
            dropHeight = newValue.second.first
            radius = newValue.second.second
        }
    }

    var body: some View {
        Canvas { context, size in
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 6))
            context.drawLayer { layer in
                let middle = size.width / 2
                let from = source.offsetBy(dx: middle, dy: 0)
                layer.fill(Path(roundedRect: from, cornerRadius: sourceRadius, style: .continuous), with: .color(.black))
                let drop = CGRect(x: middle - dropWidth / 2, y: dropTop, width: dropWidth, height: dropHeight)
                layer.fill(Path(roundedRect: drop, cornerRadius: min(radius, drop.height / 2)), with: .color(.black))
            }
        }
        .accessibilityHidden(true)
    }
}

struct NotchView: View {
    var state: NotchState
    var frozenAt: Double?
    @State private var shakes: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var open: Bool { !state.isShut }

    /// New content falls into place from above; old content simply fades. No sideways movement.
    private func fall(_ distance: CGFloat) -> AnyTransition {
        let slow = Theme.slowMotion
        let arrive = AnyTransition.offset(y: reduceMotion ? 0 : -distance).combined(with: .opacity)
        return .asymmetric(
            insertion: arrive.animation(.spring(duration: 0.4 * slow, bounce: 0.15).delay(0.08 * slow)),
            removal: .opacity.animation(.easeOut(duration: 0.08 * slow)))
    }

    var body: some View {
        Group {
            switch state.style {
            case .drop: dropStyle
            case .expanded, .island, .compact: panelStyle
            }
        }
        // Only a real notch can hide the closed shape; elsewhere it must not be seen.
        .opacity(open || state.screen == .notch || (state.style == .drop && state.screen == .plain) ? 1 : 0)
        .modifier(Shake(travel: shakes))
        .padding(.top, state.topGap)
        .frame(width: 460, height: 300, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : open ? Theme.open : Theme.close, value: state.phase)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: state.hovering)
        .onChange(of: state.phase) { _, phase in
            if case .failure = phase { withAnimation(.linear(duration: 0.5)) { shakes += 1 } }
        }
        .preferredColorScheme(.dark)
    }

    private func hover(_ hovering: Bool) {
        guard hovering != state.hovering else { return }
        state.hovering = hovering
        guard hovering else { return }
        Sounds.play(.hover)
        state.onHover?()
    }

    // MARK: Notch, island and compact: one black shape that grows

    private var panelStyle: some View {
        let bump: CGFloat = state.hovering && open ? 6 : 0
        let size = state.size
        let shape = IslandShape(radius: state.radius, flare: state.flare, floating: state.floating)
        let width = size.width + state.flare * 2 + bump, height = size.height + bump / 2
        return ZStack(alignment: .top) {
            shape.fill(.black)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(open && !state.isCompactView ? 0.35 : 0), radius: 10, y: 4)
            // A fixed canvas: content is placed once, at its final size, and revealed by the shape.
            ZStack(alignment: .top) {
                if open {
                    Group {
                        if state.style == .compact { compactContent } else { expandedContent }
                    }
                    .frame(width: size.width, alignment: .top)
                    .id(state.contentID)
                    .transition(fall(26))
                }
            }
            .frame(width: 460, height: 300, alignment: .top)
            .mask(alignment: .top) { shape.frame(width: width, height: height) }
        }
        .frame(width: 460, alignment: .top)
        .contentShape(Rectangle().size(width: width, height: height).offset(x: (460 - width) / 2))
        .onHover(perform: hover)
    }

    @ViewBuilder private var expandedContent: some View {
        switch state.phase {
        case .closed, .locked:
            EmptyView()
        case .notice(let name, let heading, let message):
            card { NoticeIcon(symbol: name, frozenAt: frozenAt) } text: {
                title(heading)
                detail(message)
            }
        case .prompt(let heading, let message):
            promptContent(heading, message).padding(.top, state.notch.height + 18)
        default:
            VStack(spacing: FaceLayout.gap) {
                glyph.frame(width: FaceLayout.notch, height: FaceLayout.notch)
                VStack(spacing: 2) {
                    switch state.phase {
                    case .success(nil): OpeningLock(finished: frozenAt != nil)
                    case .success(let text?): title(text)
                    // Gone at once on recognition, so it never lies over the padlock.
                    case .scanning: title("Looking for You").transition(.asymmetric(insertion: .opacity, removal: .identity))
                    case .hint(let text):
                        Group {
                            title(text)
                            detail(FaceCue(text)?.followUp ?? "")
                        }
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    case .failure(let text):
                        title(text)
                        detail(Words.retry)
                    case .passwordRequired:
                        title("Password Required")
                        detail(Words.password)
                    default: EmptyView()
                    }
                }
                // The padlock and the words take the same room, so the face never shifts.
                .frame(minHeight: 18)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.top, state.notch.height + 14)
        }
    }

    // MARK: Pill: drops from the top and breaks free

    private var dropStyle: some View {
        let drop = state.drop
        let source: CGRect = switch state.screen {
        case .notch: CGRect(x: -state.notch.width / 2, y: -30, width: state.notch.width, height: state.notch.height + 30)
        case .island: CGRect(x: -state.notch.width / 2, y: state.topInset, width: state.notch.width, height: state.notch.height)
        // Just out of sight, so the pill appears to pull away from the edge itself.
        case .plain: CGRect(x: -55, y: -44, width: 110, height: 40)
        }
        return ZStack(alignment: .top) {
            Liquid(source: source, sourceRadius: state.screen == .island ? state.notch.height / 2 : 12,
                   dropTop: drop.top, dropWidth: drop.width, dropHeight: drop.height, radius: drop.radius)
                .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 12, y: 6)
            ZStack(alignment: .top) {
                if open {
                    dropContent
                        .frame(width: drop.width, height: drop.height)
                        .offset(y: drop.top)
                        .id(state.contentID)
                        .transition(fall(drop.top + 24))
                }
            }
            .frame(width: 460, height: 300, alignment: .top)
            .mask(alignment: .top) {
                RoundedRectangle(cornerRadius: min(drop.radius, drop.height / 2))
                    .frame(width: drop.width, height: drop.height)
                    .offset(y: drop.top)
            }
        }
        .contentShape(Rectangle().size(width: drop.width, height: drop.top + drop.height)
            .offset(x: (460 - drop.width) / 2))
        .onHover(perform: hover)
    }

    @ViewBuilder private var dropContent: some View {
        switch state.phase {
        case .closed, .locked:
            EmptyView()
        case .scanning, .hint, .success(nil):
            VStack(spacing: 4) {
                // Always the same size, 10 from the top of the pill, whatever follows.
                glyph.frame(width: FaceLayout.pill, height: FaceLayout.pill)
                if case .hint(let text) = state.phase {
                    VStack(spacing: 2) {
                        title(text)
                        detail(FaceCue(text)?.followUp ?? "")
                    }
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        case .notice(let name, let heading, let message):
            stack { NoticeIcon(symbol: name, frozenAt: frozenAt) } text: {
                title(heading)
                detail(message)
            }
        case .prompt(let heading, let message):
            promptContent(heading, message).frame(maxHeight: .infinity)
        case .success(let text?):
            stack { glyph } text: { title(text) }
        case .failure(let text):
            stack { glyph } text: {
                title(text)
                detail(Words.retry)
            }
        case .passwordRequired:
            stack { glyph } text: {
                title("Password Required")
                detail(Words.password)
            }
        }
    }

    // MARK: Compact: either side of the camera

    @ViewBuilder private var compactContent: some View {
        switch state.phase {
        case .closed:
            EmptyView()
        case .locked, .scanning, .hint, .success(nil):
            VStack(spacing: 0) {
            compact {
                Image(systemName: state.phase == .success(nil) ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Theme.open.delay(UnlockGlyph.Beat.joined), value: state.phase)
            } trailing: {
                ZStack {
                    if state.phase != .locked {
                        UnlockGlyph(success: state.isSuccess, frozenAt: frozenAt, cue: state.cue).transition(.opacity)
                    }
                }
                .frame(width: FaceLayout.wing, height: FaceLayout.wing)
            }
            // A fixed width, so the lock and the face don't move when the shape widens.
            .frame(width: state.notch.width + 2 * NotchState.wing)
            if case .hint(let text) = state.phase {
                VStack(spacing: 2) {
                    title(text)
                    detail(FaceCue(text)?.followUp ?? "")
                }
                .padding(.top, 4)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            }
        case .success(let text?):
            card { glyph } text: { title(text) }
        case .failure(let text):
            card { glyph } text: {
                title(text)
                detail(Words.retry)
            }
        case .passwordRequired:
            card { glyph } text: {
                title("Password Required")
                detail(Words.password)
            }
        case .notice(let name, let heading, let message):
            card { NoticeIcon(symbol: name, frozenAt: frozenAt) } text: {
                title(heading)
                detail(message)
            }
        case .prompt(let heading, let message):
            promptContent(heading, message).padding(.top, state.notch.height + 18)
        }
    }

    // MARK: Pieces

    @ViewBuilder private var glyph: some View {
        switch state.phase {
        case .failure(let text): RefusedFace(message: text, frozenAt: frozenAt).id(text)
        case .passwordRequired: LockIcon(colour: .white, frozenAt: frozenAt).padding(1).scaleEffect(0.91)
        // One view for looking, hints and success.
        default: UnlockGlyph(success: state.isSuccess, frozenAt: frozenAt, cue: state.cue)
        }
    }

    private func promptContent(_ heading: String, _ message: String) -> some View {
        VStack(spacing: 12) {
            stack { NoticeIcon(symbol: "lock.fill", frozenAt: frozenAt) } text: {
                title(heading)
                // What happened on one line, what to do on the next.
                detail(message.replacingOccurrences(of: ". ", with: ".\n"))
            }
            // Two capsules, as on the island's AirDrop card.
            HStack(spacing: 10) {
                capsule("Not Now", fill: Color.white.opacity(0.13)) { state.onDismiss?() }
                capsule("Use Touch ID", fill: Theme.glow) { state.onConfirm?() }
            }
            .padding(.horizontal, 16)
        }
    }

    private func compact(@ViewBuilder leading: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 0) {
            leading().frame(width: NotchState.wing)
            Spacer(minLength: state.notch.width)
            trailing().frame(width: NotchState.wing)
        }
        .frame(height: max(state.notch.height, 36))
    }

    /// A message below the camera, with equal space above and below it.
    private func card(@ViewBuilder icon: () -> some View, @ViewBuilder text: () -> some View) -> some View {
        stack(icon: icon, text: text)
            .padding(.top, state.notch.height + 18)
    }

    /// Symbol on top, words under it, everything on the centre line.
    private func stack(@ViewBuilder icon: () -> some View, @ViewBuilder text: () -> some View) -> some View {
        VStack(spacing: 8) {
            // The picture's own height, so the room around it is what you see.
            icon().frame(width: FaceLayout.card, height: FaceLayout.card).frame(height: 70)
            VStack(spacing: 2, content: text)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func capsule(_ label: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button {
            Sounds.play(.tap)
            action()
        } label: {
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .lineLimit(1).contentTransition(.opacity)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The lock beside the camera swings open when you're recognised.
private struct OpeningLock: View {
    var finished = false
    @State private var open = false

    var body: some View {
        Image(systemName: open || finished ? "lock.open.fill" : "lock.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .onAppear { withAnimation(Theme.open.delay(UnlockGlyph.Beat.joined)) { open = true } }
    }
}

private struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(travel * .pi * 6), y: 0))
    }
}

/// Lets the first click on a button in a non-activating panel count.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The window never resizes; only its SwiftUI content moves.
@MainActor
final class NotchPresenter {
    let state = NotchState()
    private var panel: NSPanel?
    private var collapseTask: Task<Void, Never>?
    private var passthrough: Timer?
    /// While armed the closed panel stays up at the lock screen, waiting to be hovered.
    private var armed = false
    /// Set by the notch test mode; otherwise the user's choice applies.
    var forcedStyle: NotchState.Preference?
    /// Pretend the screen is of this kind (Settings previews and tests).
    var forcedKind: ScreenKind?

    func arm(onHover: @escaping () -> Void) {
        armed = true
        state.onHover = onHover
        state.phase = .locked
        present()
    }

    func disarm(after delay: TimeInterval = 0) {
        armed = false
        state.onHover = nil
        collapse(after: delay)
    }

    func show(_ phase: NotchState.Phase, for duration: TimeInterval? = nil) {
        collapseTask?.cancel()
        // What was shown, in order, so a real unlock can be checked afterwards.
        switch phase {
        case .scanning: EventLog.write("Notch: looking")
        case .hint(let text): EventLog.write("Notch: hint \(text)")
        case .success(nil): EventLog.write("Notch: success animation")
        default: break
        }
        let wasVisible = panel?.isVisible ?? false
        // The sound starts with the animation it was composed for.
        let sound = Self.sound(for: phase, after: wasVisible ? state.phase : .closed)
        present()
        if wasVisible {
            state.phase = phase
            updateInteractivity()
            if let sound { Sounds.play(sound) }
        } else {
            // Draw one closed frame first so the opening spring has somewhere to start.
            DispatchQueue.main.async { [self] in
                state.phase = phase
                updateInteractivity()
                if let sound { Sounds.play(sound) }
            }
        }
        if let text = phase.announcement {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text])
        }
        if let duration { collapse(after: duration) }
    }

    static func sound(for phase: NotchState.Phase, after previous: NotchState.Phase) -> SoundEffect? {
        // Showing the same thing again animates nothing, so says nothing.
        guard phase != previous else { return nil }
        return switch phase {
        case .scanning: .open
        case .success: .unlock
        case .failure: .failure
        case .passwordRequired, .prompt: .password
        case .notice: .notice
        case .hint: .tap
        case .closed, .locked: nil
        }
    }

    /// How long success stays up before the screen is unlocked: the arcs join and the tick
    /// draws over 1.05 s, and the finished tick is then held long enough to be seen.
    static let successHold: TimeInterval = 1.45

    /// Plays the success animation and returns once it has been seen. Unlock after this.
    func showSuccess() async {
        show(.success(nil))
        try? await Task.sleep(for: .seconds(Self.successHold))
    }

    func collapse(after delay: TimeInterval = 0) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if case .success = state.phase { Sounds.play(.retract) }
            state.phase = armed ? .locked : .closed
            updateInteractivity()
            guard !armed else { return }
            try? await Task.sleep(for: .seconds(0.75 * Theme.slowMotion))
            guard !Task.isCancelled else { return }
            close()
        }
    }

    /// Call the moment the screen unlocks: nothing of ours may stay above the desktop, and
    /// nothing from the lock screen carries over to it.
    func leaveLockScreen() {
        armed = false
        state.onHover = nil
        collapseTask?.cancel()
        close()
    }

    /// Whether anything of ours is on screen.
    var isOnScreen: Bool { panel?.isVisible ?? false }

    /// The panel is thrown away rather than reused: once moved between spaces it may not reappear.
    private func close() {
        LockScreenSpace.destroy(panel)
        panel?.orderOut(nil)
        panel = nil
        passthrough?.invalidate()
        passthrough = nil
        state.phase = .closed
        state.hovering = false
    }

    private func present() {
        if !Screen.isLocked, LockScreenSpace.exists { close() }
        let panel = ensurePanel()
        position(panel)
        let level = Screen.isLocked ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1) : .statusBar
        if !panel.isVisible || panel.level != level {
            panel.level = level
            panel.orderFrontRegardless()
            LockScreenSpace.adopt(panel)
        }
        updateInteractivity()
        if passthrough == nil {
            passthrough = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractivity() }
            }
        }
    }

    /// Clicks pass through everywhere except over the visible shape, and only when it can be used.
    private func updateInteractivity() {
        guard let panel else { return }
        var usable = armed
        if case .prompt = state.phase { usable = true }
        let size = state.size
        let rect = CGRect(x: panel.frame.midX - size.width / 2 - state.flare - 8, y: panel.frame.maxY - size.height - state.topGap - 6,
                          width: size.width + state.flare * 2 + 16, height: size.height + state.topGap + 8)
        panel.ignoresMouseEvents = !(usable && rect.contains(NSEvent.mouseLocation))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: NotchView(state: state))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        state.preference = forcedStyle
            ?? NotchState.Preference(rawValue: defaults.string(forKey: "notchStyle") ?? "") ?? .automatic
        let builtIn = NSScreen.screens.first { ScreenKind.of($0) != .plain }
        let underPointer = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let chosen = (defaults.bool(forKey: "notchFollowsPointer") ? underPointer : builtIn) ?? builtIn ?? NSScreen.main
        guard let screen = chosen else { return }

        state.screen = forcedKind ?? ScreenKind.of(screen)
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        switch state.screen {
        case .notch:
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                state.notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            } else {
                state.notch = CGSize(width: 185, height: 32)
            }
            state.topInset = 0
        case .island:
            // Apple publishes no measurements; estimated from its press images: a small pill
            // centred in the menu bar.
            state.notch = CGSize(width: 62, height: 22)
            state.topInset = max((menuBar - 22) / 2, 5)
        case .plain:
            state.notch = CGSize(width: 90, height: 0)
            state.topInset = 0
        }
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                     y: screen.frame.maxY - panel.frame.height))
    }
}
