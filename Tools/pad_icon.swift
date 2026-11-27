// Centres an exported icon on a 512-point canvas with the Dock's usual margin.
import AppKit
let a = CommandLine.arguments
let source = NSImage(contentsOfFile: a[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
source.draw(in: NSRect(x: 50, y: 50, width: 412, height: 412))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: a[2]))
