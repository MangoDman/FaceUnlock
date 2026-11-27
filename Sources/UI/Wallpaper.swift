import AppKit
import ImageIO
import SwiftUI

/// The picture on this Mac's desktop, small, to put behind the notch style previews. It is only
/// read to be drawn here.
enum DesktopWallpaper {
    /// Nil when there is no still picture to read (some moving wallpapers), or macOS was told
    /// not to let the app see the folder it is in.
    /// A picture the user has put here is used first. It is the way to choose one when macOS's
    /// own can't be read, for instance after its file has been moved.
    static let chosen = URL.applicationSupportDirectory.appending(path: "FaceUnlock/preview-wallpaper.jpg")

    @MainActor static func load() async -> NSImage? {
        // `--demo` is for the website's screenshots, which mustn't depend on whose Mac it is.
        guard !LaunchOptions.has("--demo") || LaunchOptions.has("--wallpaper") else { return nil }
        let screen = NSScreen.screens.first { ScreenKind.of($0) != .plain } ?? NSScreen.main
        let desktop = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let places = [chosen, desktop].compactMap { $0 }
        let picture = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 900]
            return places.lazy.compactMap { url in
                CGImageSourceCreateWithURL(url as CFURL, nil)
                    .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            }.first
        }.value
        if picture == nil { EventLog.write("Wallpaper preview: couldn’t read the desktop picture") }
        return picture.map { NSImage(cgImage: $0, size: .zero) }
    }
}

/// The backdrop of a preview: the desktop picture, or flowing bands of colour of our own.
struct PreviewBackdrop: View {
    var wallpaper: NSImage?

    var body: some View {
        if let wallpaper {
            // Closer in than the whole picture, and a little lifted, so the black shapes stand
            // out even against a dark sky.
            Color.clear
                .overlay { Image(nsImage: wallpaper).resizable().scaledToFill() }
                .scaleEffect(1.6, anchor: UnitPoint(x: 0.7, y: 0.75))
                .brightness(0.08)
        } else {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.35], [0.62, 0.55], [1, 0.42],
                [0, 1], [0.4, 1], [1, 1],
            ], colors: [
                Color(red: 0.10, green: 0.13, blue: 0.36), Color(red: 0.22, green: 0.25, blue: 0.62), Color(red: 0.12, green: 0.36, blue: 0.66),
                Color(red: 0.43, green: 0.24, blue: 0.66), Color(red: 0.86, green: 0.38, blue: 0.56), Color(red: 0.20, green: 0.60, blue: 0.78),
                Color(red: 0.95, green: 0.56, blue: 0.36), Color(red: 0.66, green: 0.28, blue: 0.58), Color(red: 0.12, green: 0.24, blue: 0.52),
            ])
        }
    }
}
