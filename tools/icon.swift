// Draws the app icon: the sidebar's server tile (blue gradient, white server glyph) on the macOS icon grid.
// Usage: swift tools/icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let k = CGFloat(px) / 1024
    cg.scaleBy(x: k, y: k)

    // 824×824 tile centred on the 1024 grid, with the system-style drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    cg.addPath(shape)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // linear-gradient(160deg, #5AC8FA, #0A64D6)
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let a = 160.0 * Double.pi / 180, len = 824 * (abs(sin(a)) + abs(cos(a))) / 2
    let dir = CGPoint(x: sin(a), y: cos(a))  // y flipped: CoreGraphics' origin is bottom-left
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let colors = [NSColor(srgbRed: 0x5A / 255.0, green: 0xC8 / 255.0, blue: 0xFA / 255.0, alpha: 1).cgColor,
                  NSColor(srgbRed: 0x0A / 255.0, green: 0x64 / 255.0, blue: 0xD6 / 255.0, alpha: 1).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: c.x - dir.x * len, y: c.y - dir.y * len),
                          end: CGPoint(x: c.x + dir.x * len, y: c.y + dir.y * len), options: [])
    cg.restoreGState()

    // The 24×24 server glyph at the sidebar's proportions (20px glyph in a 36px tile).
    let s = 824 * 20.0 / 36 / 24
    let origin = CGPoint(x: c.x - 12 * s, y: c.y + 12 * s)
    func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: origin.x + x * s, y: origin.y - (y + h) * s, width: w * s, height: h * s)
    }
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setFillColor(NSColor.white.cgColor)
    cg.setLineWidth(1.8 * s)
    cg.setLineJoin(.round)
    for y in [4.0, 13.0] {
        cg.addPath(CGPath(roundedRect: r(3, y, 18, 7), cornerWidth: 2 * s, cornerHeight: 2 * s, transform: nil))
        cg.strokePath()
        cg.fillEllipse(in: r(7 - 0.9, y + 3.5 - 0.9, 1.8, 1.8))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
