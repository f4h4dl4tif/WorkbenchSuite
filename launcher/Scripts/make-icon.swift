// Draws the Workbench app icon: a dark tile with a 2x2 grid of glowing tool tiles.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSShadow().with { $0.shadowColor = .black.withAlphaComponent(0.45); $0.shadowBlurRadius = 30; $0.shadowOffset = NSSize(width: 0, height: -12) }.set()
NSGradient(colors: [NSColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1), NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1)])!
    .draw(in: bodyPath, angle: -90)
NSShadow().set()
NSColor.white.withAlphaComponent(0.08).setStroke(); bodyPath.lineWidth = 4; bodyPath.stroke()

let amber = NSColor(red: 1.0, green: 0.71, blue: 0.28, alpha: 1)
let coral = NSColor(red: 1.0, green: 0.38, blue: 0.36, alpha: 1)
let tile: CGFloat = 250, gap: CGFloat = 54
let origin = (size - tile * 2 - gap) / 2
for row in 0..<2 {
    for col in 0..<2 {
        let r = NSRect(x: origin + CGFloat(col) * (tile + gap), y: origin + CGFloat(row) * (tile + gap), width: tile, height: tile)
        let p = NSBezierPath(roundedRect: r, xRadius: 64, yRadius: 64)
        if row == 1 && col == 1 {
            NSShadow().with { $0.shadowColor = coral.withAlphaComponent(0.6); $0.shadowBlurRadius = 60 }.set()
            NSGradient(colors: [amber, coral])!.draw(in: p, angle: -45)
            NSShadow().set()
        } else {
            NSColor.white.withAlphaComponent(row == 0 && col == 0 ? 0.10 : 0.16).setFill(); p.fill()
            NSColor.white.withAlphaComponent(0.12).setStroke(); p.lineWidth = 4; p.stroke()
        }
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

extension NSShadow { func with(_ f: (NSShadow) -> Void) -> NSShadow { f(self); return self } }
