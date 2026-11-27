import SwiftUI

/// One place for colour and motion. Sampled from the iOS 27.3 footage and Apple's system colours.
enum Theme {
    /// Setup progress, checkmark and buttons: system blue.
    static let accent = Color(nsColor: .systemBlue)
    /// The notch glyph sweeps between these two.
    static let glow = Color(red: 0.385, green: 0.847, blue: 0.980)
    static let deep = Color(red: 0.133, green: 0.373, blue: 0.659)
    /// App icon and settings badge, like the Face ID row in iOS Settings.
    static let iconTop = Color(red: 0.36, green: 0.89, blue: 0.47)
    static let iconBottom = Color(red: 0.10, green: 0.66, blue: 0.30)

    /// Overshoots slightly on the way out, settles without bounce on the way in.
    static let open = Animation.spring(response: 0.45 * slowMotion, dampingFraction: 0.7)
    static let close = Animation.spring(response: 0.45 * slowMotion, dampingFraction: 1.0)
    /// Above 1 only in the notch test mode, so the motion can be recorded.
    static let slowMotion: Double = LaunchOptions.has("--notch-test") ? 7 : 1
}
