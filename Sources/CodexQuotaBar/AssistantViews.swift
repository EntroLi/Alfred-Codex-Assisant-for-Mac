import AppKit

final class AlfredActionButton: NSButton {
    override var allowsVibrancy: Bool { false }
    private let callback: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        callback = action; super.init(frame: .zero)
        cell = AlfredActionButtonCell()
        self.title = title; target = self; self.action = #selector(invoke)
        bezelStyle = .rounded; font = AlfredTheme.font(ofSize: 12)
        attributedTitle = AlfredTheme.text(title, font: font!, color: AlfredTheme.ink)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { callback() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

// Keep the native bezel, tracking, keyboard and accessibility behavior. Drawing
// the title directly avoids AppKit's attributed-title vibrancy compositing path.
final class AlfredActionButtonCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        controlView.effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = AlfredTheme.ink.usingColorSpace(.deviceRGB) ?? .labelColor
            let text = NSMutableAttributedString(attributedString: AlfredTheme.text(title.string,
                font: font ?? AlfredTheme.font(ofSize: 12), color: isEnabled ? resolved : resolved.withAlphaComponent(0.45)))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        return frame
    }
}

final class QuotaPaceView: NSView {
    var remaining: Double? { didSet { needsDisplay = true } }
    var pace: QuotaPace? { didSet { needsDisplay = true; setAccessibilityValue(pace?.description ?? "节奏待计算") } }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("周额度使用与均匀进度") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let gauge = DualQuotaGauge(remaining: remaining, expectedUsed: pace?.expected)
        let track = NSRect(x: 2, y: 3, width: bounds.width - 4, height: 12)
        let palette = AlfredGaugePalette(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        func color(_ tone: AlfredGaugePalette.Tone) -> NSColor {
            NSColor(calibratedRed: tone.red, green: tone.green, blue: tone.blue, alpha: 1)
        }
        AlfredTheme.ink.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        AlfredTheme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * gauge.remainingFraction, height: track.height), xRadius: 4, yRadius: 4).fill()
        if let range = gauge.varianceRange, let difference = gauge.difference {
            let zone = NSRect(x: track.minX + track.width * range.lowerBound, y: track.minY, width: track.width * (range.upperBound - range.lowerBound), height: track.height)
            color(difference > 0 ? palette.overuse : palette.reserve).withAlphaComponent(0.30).setFill(); zone.fill()
            if difference < 0 {
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: zone).addClip()
                color(palette.natural).withAlphaComponent(0.65).setStroke()
                for x in stride(from: zone.minX - 12, through: zone.maxX + 12, by: 6) {
                    let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: zone.minY)); line.line(to: NSPoint(x: x + 12, y: zone.maxY)); line.lineWidth = 0.7; line.stroke()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let fraction = gauge.naturalStartFraction {
            let x = track.minX + track.width * fraction
            color(palette.natural).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: track.maxX - x, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            let marker = NSBezierPath(); marker.move(to: NSPoint(x: x, y: 17)); marker.line(to: NSPoint(x: x-4, y: 23)); marker.line(to: NSPoint(x: x+4, y: 23)); marker.close(); marker.fill()
        }
    }
}

final class AssistantBoardView: NSView {
    private let stack = NSStackView()
    var onAcknowledge: ((String) -> Void)?
    var onOpenNotice: ((AssistantNotice) -> Void)?
    var onSnooze: (() -> Void)?
    var onBreakDone: (() -> Void)?
    var onOpenButler: (() -> Void)?
    var onCallButler: (() -> Void)?
    var onConnectAgenda: (() -> Void)?
    var onOpenCalendar: (() -> Void)?
    var onOpenReminders: (() -> Void)?
    var agendaConnected = false
    var onExport: (() -> Void)?
    private var previousContent = ""
    private var currentBrief = ""
    private let briefField = AlfredTextField.label("", wrapping: true)
    private var currentTodos = ""
    private let todosField = AlfredTextField.label("", wrapping: true)
    func updateDailyTodos(_ todos: String) {
        currentTodos = todos
        todosField.font = AlfredTheme.font(ofSize: 12); todosField.textColor = AlfredTheme.ink; todosField.stringValue = todos
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(notices: [AssistantNotice], brief: String, agenda: String, butlerStatus: String) {
        currentBrief = brief
        briefField.font = AlfredTheme.font(ofSize: 12); briefField.textColor = AlfredTheme.ink
        briefField.stringValue = brief
        let signature = notices.map { $0.id + $0.title + $0.body + String($0.resolved) }.joined() + agenda + butlerStatus + String(agendaConnected)
        guard signature != previousContent else { return }; previousContent = signature
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let openButler = AlfredActionButton("打开管家", action: { [weak self] in self?.onOpenButler?() })
        let callButler = AlfredActionButton("打开语音入口", action: { [weak self] in self?.onCallButler?() })
        openButler.isEnabled = onOpenButler != nil; callButler.isEnabled = onCallButler != nil
        add(card("管家", [text(butlerStatus), row([openButler, callButler])]))
        add(text("待处理 · \(notices.count)", bold: true))
        if notices.isEmpty { add(text("暂时没有待处理提醒。")) }
        for notice in notices {
            var buttons: [NSView] = []
            if notice.kind == "break" {
                buttons = [AlfredActionButton("稍后5分钟", action: { [weak self] in self?.onSnooze?() }), AlfredActionButton("已活动", action: { [weak self] in self?.onBreakDone?() })]
            } else {
                if notice.threadID != nil || notice.kind == "calendar" || notice.kind == "todo" { buttons.append(AlfredActionButton("查看信号", action: { [weak self] in self?.onOpenNotice?(notice) })) }
                buttons.append(AlfredActionButton("已读", action: { [weak self] in self?.onAcknowledge?(notice.id) }))
            }
            add(noticeCard(notice, buttons: buttons))
        }
        let connect = AlfredActionButton(agendaConnected ? "重新读取安排" : "连接日历与提醒事项", action: { [weak self] in self?.onConnectAgenda?() })
        connect.isEnabled = onConnectAgenda != nil
        let calendar = AlfredActionButton("打开日历", action: { [weak self] in self?.onOpenCalendar?() })
        let reminders = AlfredActionButton("打开提醒事项", action: { [weak self] in self?.onOpenReminders?() })
        calendar.isEnabled = onOpenCalendar != nil; reminders.isEnabled = onOpenReminders != nil
        add(card("下一场日程 · 优先待办", [text(agenda), row([calendar, reminders]), connect]))
        add(card("哥谭今日行动清单", [todosField, AlfredActionButton("复制待办", action: { [weak self] in
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self?.currentTodos ?? "", forType: .string)
        })]))
        add(card("蝙蝠洞日报", [briefField, row([AlfredActionButton("复制日报", action: { [weak self] in
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self?.currentBrief ?? "", forType: .string)
        }), AlfredActionButton("导出日报与待办", action: { [weak self] in self?.onExport?() })])]))
    }
    private func add(_ view: NSView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    private func text(_ text: String, bold: Bool = false) -> NSTextField {
        let label = AlfredTextField.label(text, wrapping: true); label.font = AlfredTheme.font(ofSize: 12, weight: bold ? .bold : .regular); label.textColor = AlfredTheme.ink
        return label
    }
    private func row(_ items: [NSView]) -> NSStackView { let row = NSStackView(views: items); row.orientation = .horizontal; row.spacing = 8; return row }
    private func noticeCard(_ notice: AssistantNotice, buttons: [NSView]) -> NSView {
        let emblem = NSImageView(); emblem.image = AlfredTheme.bat(size: NSSize(width: 40, height: 24))
        emblem.setAccessibilityLabel("Alfred 蝙蝠徽记")
        emblem.widthAnchor.constraint(equalToConstant: 40).isActive = true
        emblem.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let story = text(AlfredNotificationStory(kind: notice.kind).subtitle)
        story.font = AlfredTheme.font(ofSize: 10, weight: .bold); story.textColor = AlfredTheme.accent
        let heading = row([emblem, story]); heading.alignment = .centerY
        return card(notice.title + (notice.resolved ? " · 已恢复" : ""), [heading, text(notice.body), row(buttons)])
    }
    private func card(_ title: String, _ items: [NSView]) -> NSView {
        let inner = NSStackView(views: [text(title, bold: true)] + items); inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 8
        let card = AlfredCardView(); inner.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(inner)
        for item in inner.arrangedSubviews { item.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14), inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)])
        return card
    }
}
