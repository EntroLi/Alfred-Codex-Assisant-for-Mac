import AppKit
import Foundation

// Original bat silhouette shared with Alfred's UI. No downloaded artwork.
@main enum NotificationArtworkGenerator {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, caption) in [("signal", "BAT-SIGNAL"), ("reserve", "WAYNE RESERVE"), ("batcave", "BATCAVE")] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: 512, height: 512)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let full = NSRect(x: 0, y: 0, width: 512, height: 512)
            AlfredTheme.graphite.setFill(); NSBezierPath(rect: full).fill()
            // A quiet signal beam and Gotham skyline keep the emblem readable at thumbnail size.
            let beam = NSBezierPath(); beam.move(to: NSPoint(x: 355, y: 73)); beam.line(to: NSPoint(x: 93, y: 366)); beam.line(to: NSPoint(x: 440, y: 366)); beam.close()
            AlfredTheme.gold.withAlphaComponent(0.07).setFill(); beam.fill()
            for i in 0..<12 {
                let height = CGFloat([38, 61, 44, 86, 53, 69][i % 6])
                NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
                NSRect(x: CGFloat(i) * 45 - 10, y: 0, width: 36, height: height).fill()
            }
            let oval = NSBezierPath(ovalIn: NSRect(x: 52, y: 197, width: 408, height: 238))
            AlfredTheme.gold.withAlphaComponent(0.06).setFill(); oval.fill()
            AlfredTheme.gold.withAlphaComponent(0.6).setStroke(); oval.lineWidth = 3; oval.stroke()
            AlfredTheme.bat(size: NSSize(width: 326, height: 174)).draw(in: NSRect(x: 93, y: 237, width: 326, height: 174))
            draw("ALFRED", rect: NSRect(x: 0, y: 121, width: 512, height: 62), size: 42, color: AlfredTheme.gold)
            draw(caption, rect: NSRect(x: 0, y: 83, width: 512, height: 33), size: 18, color: NSColor(calibratedWhite: 0.76, alpha: 1))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("notification-" + name + ".png"))
        }
    }
    static func draw(_ text: String, rect: NSRect, size: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: rect, withAttributes: [.font: AlfredTheme.font(ofSize: size, weight: .bold), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
