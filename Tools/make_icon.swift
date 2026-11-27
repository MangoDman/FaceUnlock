// Draws the icon's two layers. The Liquid Glass finish itself is
// Apple's: Resources/AppIcon.icon is an Icon Composer document that macOS renders.
// Usage: Tools/make_icon.sh
import SwiftUI

@main
struct MakeIcon {
    @MainActor static func main() throws {
        // Same drawing as website/assets/face.svg, on a 100-point grid. Two layers, so the face
        // gets the glass while the arcs stay a flat, dimmer white.
        let round = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        func save(_ name: String, _ draw: @escaping (GraphicsContext) -> Void) throws {
            let art = Canvas { context, size in
                context.scaleBy(x: size.width / 100, y: size.height / 100)
                draw(context)
            }
            .frame(width: 800, height: 800)
            .frame(width: 1024, height: 1024)
            guard let image = ImageRenderer(content: art).cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { fatalError("render failed") }
            try data.write(to: URL(filePath: CommandLine.arguments[1]).appending(path: name))
        }
        // Every number here was measured from the reference mark.
        let ink = GraphicsContext.Shading.color(.white)
        try save("arcs.png") { context in
            for centre in [-90.0, 0, 90, 180] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 50, y: 50), radius: 44.5, startAngle: .degrees(centre - 31),
                           endAngle: .degrees(centre + 31), clockwise: false)
                context.stroke(arc, with: ink, style: round(2.88))
            }
        }
        try save("face.png") { context in
            context.stroke(Path(ellipseIn: CGRect(x: 17.64, y: 17.64, width: 64.72, height: 64.72)), with: ink, style: round(4.22))
            var eyes = Path()
            for x in [37.17, 62.83] {
                eyes.move(to: CGPoint(x: x, y: 39.76))
                eyes.addLine(to: CGPoint(x: x, y: 44.94))
            }
            context.stroke(eyes, with: ink, style: round(4.69))
            var nose = Path()
            nose.move(to: CGPoint(x: 50.84, y: 40.01))
            nose.addLine(to: CGPoint(x: 50.84, y: 50.25))
            nose.addQuadCurve(to: CGPoint(x: 48.27, y: 52.81), control: CGPoint(x: 50.84, y: 52.81))
            nose.addLine(to: CGPoint(x: 47.09, y: 52.81))
            context.stroke(nose, with: ink, style: round(4.14))
            var smile = Path()
            smile.move(to: CGPoint(x: 40.23, y: 60.21))
            smile.addQuadCurve(to: CGPoint(x: 59.27, y: 60.21), control: CGPoint(x: 49.75, y: 68.8))
            context.stroke(smile, with: ink, style: round(4.12))
        }
    }
}
