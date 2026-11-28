import SwiftUI

/// One place for colour and motion. Sampled from the iOS 27.3 footage and Apple's system colours.
enum Theme {
    /// Setup progress, checkmark and buttons: system blue.
    static let accent = Color(nsColor: .systemBlue)
    /// The same blue on the black shape: Apple's system blue for dark backgrounds (0, 145, 255),
    /// written out so it is the same wherever it is drawn. The face, icons and buttons use it.
    static let glow = Color(red: 0, green: 145 / 255, blue: 1)
    /// A shade of it, which the face breathes toward while looking.
    static let deep = Color(red: 0, green: 0.36, blue: 0.68)
    /// App icon and settings badge, like the Face ID row in iOS Settings.
    static let iconTop = Color(red: 0.36, green: 0.89, blue: 0.47)
    static let iconBottom = Color(red: 0.10, green: 0.66, blue: 0.30)

    /// Overshoots slightly on the way out, settles without bounce on the way in.
    static let open = Animation.spring(response: 0.45 * slowMotion, dampingFraction: 0.7)
    static let close = Animation.spring(response: 0.45 * slowMotion, dampingFraction: 1.0)
    /// Above 1 only in the notch test mode, so the motion can be recorded.
    static let slowMotion: Double = LaunchOptions.has("--notch-test") ? 7 : 1
}
