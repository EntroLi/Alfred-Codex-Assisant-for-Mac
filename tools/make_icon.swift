import AppKit
import Foundation
// Original bat artwork, drawn at native icon sizes. No downloaded assets.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let n = CGFloat(pixels)
        AlfredTheme.graphite.setFill()
        NSBezierPath(roundedRect: NSRect(x: n * 0.07, y: n * 0.07, width: n * 0.86, height: n * 0.86), xRadius: n * 0.19, yRadius: n * 0.19).fill()
        let oval = NSBezierPath(ovalIn: NSRect(x: n * 0.16, y: n * 0.30, width: n * 0.68, height: n * 0.40))
        AlfredTheme.gold.withAlphaComponent(0.65).setStroke(); oval.lineWidth = max(1, n * 0.012); oval.stroke()
        AlfredTheme.bat(size: NSSize(width: n * 0.58, height: n * 0.31)).draw(in: NSRect(x: n * 0.21, y: n * 0.355, width: n * 0.58, height: n * 0.31))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
