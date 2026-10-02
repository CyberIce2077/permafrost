// Draws the app icon: tools/AppIcon.svg (the design's "Icicle Server" concept) on the macOS icon grid.
// Usage: swift tools/icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let svg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AppIcon.svg")
let art = NSImage(contentsOf: svg)!

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let cg = NSGraphicsContext.current!.cgContext
    let k = CGFloat(px) / 1024
    cg.scaleBy(x: k, y: k)

    // 824×824 tile centred on the 1024 grid with the system-style drop shadow. The artwork's own
    // corners (rx 22.5 of 100) come out at the grid's 185 pt.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    cg.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()
    art.draw(in: tile)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
