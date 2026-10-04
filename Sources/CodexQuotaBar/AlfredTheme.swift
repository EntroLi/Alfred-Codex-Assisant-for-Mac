import AppKit

/// A small original vector bat: shared by the menu bar, popover and Touch Bar.
enum AlfredTheme {
    static let gold = NSColor(calibratedRed: 0.91, green: 0.73, blue: 0.34, alpha: 1)
    static let graphite = NSColor(calibratedRed: 0.085, green: 0.095, blue: 0.115, alpha: 1)
    static let ink = adaptive(light: NSColor(calibratedWhite: 0.13, alpha: 1), dark: NSColor(calibratedWhite: 0.94, alpha: 1))
    static let muted = adaptive(light: NSColor(calibratedWhite: 0.38, alpha: 1), dark: NSColor(calibratedWhite: 0.72, alpha: 1))
    static let accent = adaptive(light: NSColor(calibratedRed: 0.48, green: 0.32, blue: 0.06, alpha: 1), dark: gold)
    static let surface = adaptive(light: NSColor(calibratedWhite: 0.97, alpha: 1), dark: NSColor(calibratedWhite: 0.13, alpha: 1))
    static let cardFill = adaptive(light: NSColor.white.withAlphaComponent(0.55), dark: NSColor.black.withAlphaComponent(0.16))
    static let border = adaptive(light: NSColor.black.withAlphaComponent(0.09), dark: NSColor.white.withAlphaComponent(0.13))

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight >= .semibold ? "ComicSansMS-Bold" : "ComicSansMS"
        let base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        let chinese = NSFontDescriptor(name: weight >= .semibold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size)
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [chinese]]), size: size) ?? base
    }
    static func text(_ string: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        let latin = self.font(ofSize: font.pointSize, weight: bold ? .bold : .regular)
        let chinese = NSFont(name: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: font.pointSize) ?? latin
        let result = NSMutableAttributedString(string: string, attributes: [.font: latin, .foregroundColor: color])
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byComposedCharacterSequences) { part, range, _, _ in
            if let part, part.unicodeScalars.contains(where: { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }) {
                result.addAttribute(.font, value: chinese, range: NSRange(range, in: string))
            }
        }
        return result
    }

    static func bat(size: NSSize = NSSize(width: 22, height: 14), template: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let points: [(CGFloat, CGFloat)] = [
                (0.02,0.86),(0.22,0.70),(0.35,0.72),(0.40,0.92),(0.45,0.66),
                (0.55,0.66),(0.60,0.92),(0.65,0.72),(0.78,0.70),(0.98,0.86),
                (0.86,0.34),(0.76,0.48),(0.67,0.25),(0.59,0.36),(0.50,0.05),
                (0.41,0.36),(0.33,0.25),(0.24,0.48),(0.14,0.34)
            ]
            let path = NSBezierPath()
            for (i, p) in points.enumerated() {
                let point = NSPoint(x: rect.minX + p.0 * rect.width, y: rect.minY + p.1 * rect.height)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            (template ? NSColor.black : gold).setFill()
            path.fill()
            return true
        }
        image.isTemplate = template
        return image
    }
}
