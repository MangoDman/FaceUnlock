#if DEBUG
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The moving pictures in the README and on the website, drawn frame by frame with the app's own
/// glyph and measurements. Written by `--snapshots <folder>`; `--backdrop <picture>` sets what
/// is behind the screen.
@MainActor
enum Media {
    private static let fps = 25.0

    static func render(to folder: URL) {
        let arguments = CommandLine.arguments
        let backdrop = arguments.firstIndex(of: "--backdrop")
            .flatMap { $0 + 1 < arguments.count ? NSImage(contentsOfFile: arguments[$0 + 1]) : nil }

        for pill in [false, true] {
            // Locked, looking, recognised, held, gone.
            let times = stride(from: 0.0, to: 5.4, by: 1 / fps)
            gif(times.map { image(unlock(at: $0, pill: pill, backdrop: backdrop)) },
                to: folder.appending(path: pill ? "unlock-pill.gif" : "unlock-compact.gif"))
        }
        for (name, time) in [("anim-1", 1.9), ("anim-2", 3.38), ("anim-3", 4.3), ("anim-4", 4.76)] {
            png(image(unlock(at: time, pill: false, backdrop: backdrop)), to: folder.appending(path: "\(name).png"))
        }
        gif(stride(from: 0.0, to: 8.4, by: 1 / 20).map { time in
            image(InstructionGlyph(frozenAt: time)
                .environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
                .frame(width: 150, height: 150)
                .frame(width: 220, height: 200)
                .background(Color(white: 0.07)))
        }, delay: 1.0 / 20, to: folder.appending(path: "setup.gif"))
    }

    /// The top of a locked screen at one moment of an unlock.
    private static func unlock(at time: Double, pill: Bool, backdrop: NSImage?) -> some View {
        let look = 1.0, recognised = 3.0, leave = recognised + 1.6
        let success = time >= recognised
        let since = success ? time - recognised : nil
        func smooth(_ from: Double, _ length: Double) -> Double {
            let x = min(max((time - from) / length, 0), 1)
            return x * x * (3 - 2 * x)
        }
        let arrived = smooth(look, 0.35), gone = smooth(leave, 0.35)
        let glyph = Canvas { context, size in
            UnlockGlyph.draw(&context, size: size, looking: (success ? recognised : time) - look, since: since)
        }

        return ZStack(alignment: .top) {
            if let backdrop {
                Image(nsImage: backdrop).resizable().scaledToFill().frame(width: 420, height: 150).clipped()
                    .brightness(0.12)
            } else {
                LinearGradient(colors: [Color(red: 0.2, green: 0.22, blue: 0.4), Color(red: 0.06, green: 0.07, blue: 0.14)],
                               startPoint: .top, endPoint: .bottom)
            }
            if pill {
                let shown = arrived * (1 - gone)
                Circle().fill(.black)
                    .frame(width: 96, height: 96)
                    .overlay { glyph.frame(width: 70, height: 70) }
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    .offset(y: -100 + 110 * shown)
            } else {
                // Beside the camera: the padlock one side, the face the other.
                let open = since.map { $0 >= UnlockGlyph.Beat.joined } ?? false
                let width = 185 + 112 * (1 - gone), height = 32 + 4 * (1 - gone)
                UnevenRoundedRectangle(bottomLeadingRadius: 18 - 7 * gone, bottomTrailingRadius: 18 - 7 * gone,
                                       style: .continuous)
                    .fill(.black)
                    .frame(width: width, height: height)
                    .overlay {
                        HStack(spacing: 0) {
                            Image(systemName: open ? "lock.open.fill" : "lock.fill")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 56)
                            Spacer(minLength: 185)
                            glyph.frame(width: 27, height: 27).opacity(arrived).frame(width: 56)
                        }
                        .frame(width: 297)
                        .opacity(1 - gone)
                    }
                    .clipped()
            }
        }
        .frame(width: 420, height: 150, alignment: .top)
        .clipped()
    }

    private static func image(_ view: some View) -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage!
    }

    private static func gif(_ frames: [CGImage], delay: Double = 1 / fps, to url: URL) {
        guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return }
        CGImageDestinationSetProperties(file, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(file, frame, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(file)
    }

    private static func png(_ frame: CGImage, to url: URL) {
        try? NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
