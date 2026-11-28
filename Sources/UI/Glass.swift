// Following the Liquid Glass setting in System Settings › Appearance.
//
// Standard controls and the system's own glass follow the slider by themselves. The icon tiles
// in Settings and the large icons in setup are drawn here, so they read the same number to match.
// Everything in the notch is deliberately left solid: it must be readable at once, and glass in a
// panel that is never the active window loses its colour.

import SwiftUI

enum GlassSetting {
    /// How clear the user wants glass: 0 is fully tinted (solid), 1 the clearest.
    ///
    /// macOS has no API for the slider. `NSGlassTintAmount` is where it keeps it (1 is fully
    /// tinted), so if that ever moves, the icons simply stay solid.
    static var clearness: Double {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
              let tint = UserDefaults.standard.object(forKey: "NSGlassTintAmount") else { return 0 }
        // A number normally; a string when given as a launch option.
        let amount = (tint as? NSNumber)?.doubleValue ?? (tint as? String).flatMap(Double.init) ?? 1
        return 1 - min(max(amount, 0), 1)
    }
}

extension View {
    /// Gives a solid icon the look of glass, as strongly as the user has asked for it.
    func glassy() -> some View { modifier(Glassy()) }
}

private struct Glassy: ViewModifier {
    @State private var clearness = GlassSetting.clearness

    func body(content: Content) -> some View {
        look(content)
            // The slider is moved in System Settings, so look again on coming back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                clearness = GlassSetting.clearness
            }
            .onAppear { clearness = GlassSetting.clearness }
    }

    @ViewBuilder private func look(_ content: Content) -> some View {
        if clearness > 0.01 {
            content
                // Light caught along the top and bottom of the glass.
                .overlay {
                    LinearGradient(stops: [.init(color: .white.opacity(0.7 * clearness), location: 0),
                                           .init(color: .white.opacity(0.12 * clearness), location: 0.42),
                                           .init(color: .black.opacity(0.3 * clearness), location: 0.68),
                                           .init(color: .white.opacity(0.45 * clearness), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .blendMode(.sourceAtop)
                        .allowsHitTesting(false)
                }
                .compositingGroup()
                .opacity(1 - 0.12 * clearness)
        } else {
            content
        }
    }
}
