import AppKit

/// Read-only labels have an explicit copy menu instead of the field editor's
/// unrelated Lookup/Services menu. The menu owns normal system text colours.
final class AlfredTextField: NSTextField {
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize {
        guard cell?.wraps == true else { return super.intrinsicContentSize }
        // A paragraph supplies height at its assigned width, never a minimum window width.
        let width = bounds.width > 0 ? bounds.width : 382
        let rect = attributedStringValue.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = ceil((font ?? AlfredTheme.font(ofSize: 12)).boundingRectForFont.height)
        let height = maximumNumberOfLines > 0 ? min(ceil(rect.height), lineHeight * CGFloat(maximumNumberOfLines)) : ceil(rect.height)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(lineHeight, height))
    }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged, cell?.wraps == true { invalidateIntrinsicContentSize() }
    }
    override var stringValue: String {
        get { super.stringValue }
        set {
            super.attributedStringValue = AlfredTheme.text(newValue, font: font ?? AlfredTheme.font(ofSize: 12), color: textColor ?? .labelColor)
            invalidateIntrinsicContentSize(); needsDisplay = true
        }
    }
    override var font: NSFont? { didSet { restyle() } }
    override var textColor: NSColor? { didSet { restyle() } }
    func restyle() {
        super.attributedStringValue = AlfredTheme.text(super.stringValue, font: font ?? AlfredTheme.font(ofSize: 12), color: textColor ?? .labelColor)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    // Keep native text/accessibility/copy semantics, but draw read-only text directly.
    // The cell's attributed-text compositing can disappear inside a scrolled popover.
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (textColor ?? .labelColor).usingColorSpace(.deviceRGB) ?? .labelColor
            let text = NSMutableAttributedString(attributedString: AlfredTheme.text(stringValue,
                font: font ?? AlfredTheme.font(ofSize: 12), color: color))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = lineBreakMode
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }
    static func label(_ text: String, wrapping: Bool = false) -> AlfredTextField {
        let field = AlfredTextField(frame: .zero)
        field.isEditable = false; field.isSelectable = false
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.cell?.wraps = wrapping; field.cell?.isScrollable = !wrapping
        field.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        if wrapping { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        field.stringValue = text
        field.wantsLayer = true
        return field
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "文本")
        menu.font = AlfredTheme.font(ofSize: 13)
        let copy = NSMenuItem(title: "复制文本", action: #selector(copyLabel), keyEquivalent: "")
        copy.target = self; copy.isEnabled = !stringValue.isEmpty
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copy)
        return menu
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    @objc private func copyLabel() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stringValue, forType: .string)
    }
}

final class AlfredCardView: NSView {
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        AlfredTheme.cardFill.setFill(); path.fill()
        AlfredTheme.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Glass belongs to the navigation layer; reading cards remain quiet and legible.
final class AlfredNavigationGlass: NSView {
    let content = NSView()
    let usesNativeGlass: Bool
    override init(frame: NSRect) {
        if #available(macOS 26.0, *) { usesNativeGlass = true } else { usesNativeGlass = false }
        super.init(frame: frame)
        let host: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = 18; glass.contentView = content
            host = glass
        } else {
            let effect = NSVisualEffectView(); effect.material = .popover
            effect.state = .active; effect.blendingMode = .withinWindow
            effect.addSubview(content); host = effect
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: effect.leadingAnchor), content.trailingAnchor.constraint(equalTo: effect.trailingAnchor), content.topAnchor.constraint(equalTo: effect.topAnchor), content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        }
        host.translatesAutoresizingMaskIntoConstraints = false; addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor), host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
