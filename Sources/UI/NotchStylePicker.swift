import SwiftUI

/// Settings: the styles shown live, side by side, with a slider to pull between them.
struct NotchStylePicker: View {
    @Bindable var app: AppModel

    private static let styles: [(NotchState.Preference, String)] =
        [(.expanded, "Notch"), (.drop, "Pill"), (.compact, "Compact")]

    /// What's in effect: "Automatic" means the notch grows here, and a pill elsewhere.
    private var selected: Int {
        let kind = NSScreen.screens.map(ScreenKind.of).first { $0 != .plain } ?? .plain
        let style = app.notchStyle == .automatic ? (kind == .plain ? .drop : .expanded) : app.notchStyle
        return Self.styles.firstIndex { $0.0 == style } ?? 0
    }

    private func choose(_ index: Int) {
        guard index != selected || app.notchStyle == .automatic else { return }
        app.notchStyle = Self.styles[index].0
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        app.preview(.unlock)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Self.styles.indices, id: \.self) { index in
                    Button { choose(index) } label: {
                        VStack(spacing: 6) {
                            MiniScreen(preference: Self.styles[index].0)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(index == selected ? Theme.accent : .white.opacity(0.1),
                                                  lineWidth: index == selected ? 3 : 1))
                            Text(Self.styles[index].1)
                                .font(.callout.weight(index == selected ? .semibold : .regular))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.styles[index].1)
                    .accessibilityAddTraits(index == selected ? .isSelected : [])
                }
            }

            PullSlider(titles: Self.styles.map(\.1), selected: selected, choose: choose)
        }
        .padding(.vertical, 4)

        Toggle(isOn: Binding(get: { app.notchStyle == .automatic },
                             set: { app.notchStyle = $0 ? .automatic : Self.styles[selected].0 })) {
            RowLabel("Choose for Each Screen", "wand.and.stars")
        }
        .help("Grows a notch or Dynamic Island; drops a pill on screens with neither")

        LabeledContent {
            Picker("Preview as", selection: $app.previewKind) {
                Text("This Mac").tag(ScreenKind?.none)
                ForEach(ScreenKind.allCases) { Text($0.title).tag(ScreenKind?.some($0)) }
            }
            .labelsHidden()
            .onChange(of: app.previewKind) { _, _ in app.preview(.unlock) }
        } label: {
            RowLabel("Preview As", "macbook")
        }
    }
}

/// A segmented track whose knob can be clicked or dragged.
private struct PullSlider: View {
    var titles: [String]
    var selected: Int
    var choose: (Int) -> Void
    /// Knob position while it's being pulled.
    @State private var drag: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let segment = (proxy.size.width - 4) / CGFloat(titles.count)
            let x = drag ?? segment * CGFloat(selected)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Theme.accent.gradient)
                    .frame(width: segment, height: 28)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    // Stretches a little while pulled.
                    .scaleEffect(x: drag == nil ? 1 : 1.06, y: drag == nil ? 1 : 0.94)
                    .offset(x: 2 + x)
                HStack(spacing: 0) {
                    ForEach(titles.indices, id: \.self) { index in
                        Text(titles[index])
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(index == selected && drag == nil ? .white : .primary)
                            .frame(width: segment)
                    }
                }
                .offset(x: 2)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    drag = min(max(value.location.x - segment / 2, 0), segment * CGFloat(titles.count - 1))
                }
                .onEnded { value in
                    let index = Int((value.location.x - 2) / segment)
                    withAnimation(Theme.open) { drag = nil }
                    choose(min(max(index, 0), titles.count - 1))
                })
            .animation(Theme.open, value: selected)
        }
        .frame(height: 32)
        .accessibilityRepresentation {
            Picker("Notch style", selection: Binding(get: { selected }, set: choose)) {
                ForEach(titles.indices, id: \.self) { Text(titles[$0]).tag($0) }
            }
        }
    }
}

/// A thumbnail of the top of a screen playing look → recognized.
private struct MiniScreen: View {
    var preference: NotchState.Preference
    @State private var state = NotchState()

    private let scale: CGFloat = 0.42

    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.45), Color(red: 0.24, green: 0.52, blue: 0.55)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        // An overlay, so the full-size notch view never widens the card.
        .overlay(alignment: .top) {
            NotchView(state: state)
                .scaleEffect(scale, anchor: .top)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
        .task {
            state.preference = preference
            state.notch = CGSize(width: 150, height: 30)
            while !Task.isCancelled {
                for (phase, seconds) in [(NotchState.Phase.closed, 0.7), (.scanning, 2.2), (.success(nil), 1.6)] {
                    state.phase = phase
                    try? await Task.sleep(for: .seconds(seconds))
                    if Task.isCancelled { return }
                }
            }
        }
    }
}
