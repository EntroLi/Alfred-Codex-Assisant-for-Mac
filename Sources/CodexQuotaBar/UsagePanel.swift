import AppKit

final class QuotaPanelContentView: NSView {
    var onOpenThread: ((String) -> Void)?
    private let taskRows = NSStackView()
    private let recordRows = NSStackView()
    private var quota: QuotaSnapshot?
    private var activity = CodexActivitySnapshot.idle
    private var analytics = UsageAnalyticsSnapshot.empty
    private var statusText = "正在读取 Codex 额度..."
    private var rangeDays = 7
    private var barHitRegions: [(NSRect, DailyUsageBucket)] = []
    private var hoveredBucket: DailyUsageBucket?
    private var hoverTrackingArea: NSTrackingArea?
    private lazy var rangeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["7天", "30天"], trackingMode: .selectOne, target: self, action: #selector(rangeChanged))
        control.selectedSegment = 0
        control.controlSize = .small
        return control
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(rangeControl)
        for rows in [taskRows, recordRows] { rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 4; addSubview(rows) }
        rangeControl.font = AlfredTheme.font(ofSize: 12)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = barHitRegions.first { $0.0.contains(point) }?.1
        if next?.date != hoveredBucket?.date {
            hoveredBucket = next
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBucket = nil
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        taskRows.frame = NSRect(x: 20, y: 354, width: bounds.width - 40, height: 244)
        recordRows.frame = NSRect(x: 20, y: 643, width: bounds.width - 40, height: 55)
        rangeControl.frame = NSRect(x: bounds.width - 112, y: 99, width: 92, height: 24)
    }

    func update(snapshot: QuotaSnapshot) {
        quota = snapshot
        statusText = "更新于 \(Self.time(snapshot.fetchedAt))"
        needsDisplay = true
    }

    func update(activity: CodexActivitySnapshot) {
        self.activity = activity
        needsDisplay = true
    }

    func update(analytics: UsageAnalyticsSnapshot) {
        self.analytics = analytics
        rebuildNativeRows()
        hoveredBucket = nil
        needsDisplay = true
    }

    func setLoading(keepingExistingData: Bool) {
        statusText = keepingExistingData ? "正在刷新，旧数据继续显示" : "正在读取 Codex 额度..."
        needsDisplay = true
    }

    func show(error: Error) {
        statusText = error.localizedDescription
        needsDisplay = true
    }

    @objc private func rangeChanged() {
        rangeDays = rangeControl.selectedSegment == 0 ? 7 : 30
        hoveredBucket = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawText(activity.displayText, x: 20, y: 10, width: bounds.width - 40, font: AlfredTheme.font(ofSize: 12, weight: .medium))

        if let quota {
            let y: CGFloat = 39
            if let weekly = quota.weekly {
                drawQuotaRow("周额度", window: weekly, y: y)
            }
        } else {
            drawText("额度读取中...", x: 20, y: 48, width: 410, font: AlfredTheme.font(ofSize: 12, weight: .medium))
        }
        drawText(statusText, x: 20, y: 61, width: 420, font: AlfredTheme.font(ofSize: 10), color: AlfredTheme.ink.withAlphaComponent(0.68))
        divider(y: 83)

        drawText("用量统计", x: 20, y: 99, width: 160, font: AlfredTheme.font(ofSize: 14, weight: .bold))
        drawSummary(y: 133)
        drawDailyChart(y: 195)
        divider(y: 311)
        drawText("最近任务", x: 20, y: 329, width: 160, font: AlfredTheme.font(ofSize: 12, weight: .bold))
        divider(y: 602)
        drawText("历史纪录", x: 20, y: 620, width: 160, font: AlfredTheme.font(ofSize: 12, weight: .bold))
        divider(y: 700)
        drawCalibration(y: 717)
    }

    private func drawQuotaRow(_ title: String, window: LimitWindow, y: CGFloat) {
        drawText(title, x: 20, y: y + 1, width: 52, font: AlfredTheme.font(ofSize: 12, weight: .semibold))
        let barRect = NSRect(x: 82, y: y + 2, width: 175, height: 14)
        drawSegments(in: barRect, percent: window.remainingPercent)
        drawText("\(Int(window.remainingPercent.rounded()))%", x: 265, y: y + 1, width: 42, font: AlfredTheme.font(ofSize: 11, weight: .medium))
        drawText("RESET", x: 313, y: y + 2, width: 38, font: AlfredTheme.font(ofSize: 9), color: AlfredTheme.muted)
        drawText(QuotaRowView.format(date: window.resetDate), x: 356, y: y + 1, width: 82, font: AlfredTheme.font(ofSize: 10), alignment: .right)
    }

    private func drawSegments(in rect: NSRect, percent: Double) {
        let gap: CGFloat = 3
        let width = (rect.width - 9 * gap) / 10
        let filled = quotaLevel(for: percent)
        for index in 0..<10 {
            let segment = NSRect(x: rect.minX + CGFloat(index) * (width + gap), y: rect.minY, width: width, height: rect.height)
            let path = NSBezierPath(roundedRect: segment, xRadius: 3, yRadius: 3)
            (index < filled ? (percent < 20 ? NSColor.systemRed : AlfredTheme.accent) : AlfredTheme.ink.withAlphaComponent(0.08)).setFill()
            path.fill()
        }
    }

    private func drawSummary(y: CGFloat) {
        let range = rangeDays == 7 ? analytics.last7Days : analytics.last30Days
        let items: [(String, UsageSummary)] = [("今天", analytics.today), ("近\(rangeDays)天", range), ("历史累计", analytics.allTime)]
        let columnWidth = (bounds.width - 40) / 3
        for (index, item) in items.enumerated() {
            let x = 20 + CGFloat(index) * columnWidth
            if index > 0 {
                AlfredTheme.ink.withAlphaComponent(0.08).setFill()
                NSRect(x: x - 1, y: y, width: 1, height: 47).fill()
            }
            drawText(item.0, x: x + 8, y: y, width: columnWidth - 16, font: AlfredTheme.font(ofSize: 10, weight: .medium), color: AlfredTheme.ink.withAlphaComponent(0.62))
            drawText(analytics.showWeeklyEstimates ? Self.week(item.1.weeklyEquivalent) : Self.tokens(item.1.tokens.total), x: x + 8, y: y + 16, width: columnWidth - 16, font: AlfredTheme.font(ofSize: 14, weight: .bold))
            drawText(analytics.showWeeklyEstimates ? Self.tokens(item.1.tokens.total) : "本机日志", x: x + 8, y: y + 34, width: columnWidth - 12, font: AlfredTheme.font(ofSize: 9, weight: .regular), color: AlfredTheme.ink.withAlphaComponent(0.62))
        }
    }

    private func drawDailyChart(y: CGFloat) {
        let selected = Array(analytics.dailyBuckets.suffix(rangeDays))
        barHitRegions.removeAll(keepingCapacity: true)
        drawText(analytics.showWeeklyEstimates ? "每日消耗（估算）" : "每日 token（周换算样本不足）", x: 20, y: y, width: 220, font: AlfredTheme.font(ofSize: 11, weight: .semibold))
        guard !selected.isEmpty else {
            drawText("正在扫描历史日志...", x: 20, y: y + 35, width: 400, font: AlfredTheme.font(ofSize: 11), color: AlfredTheme.ink.withAlphaComponent(0.6))
            return
        }
        let chart = NSRect(x: 24, y: y + 23, width: bounds.width - 48, height: 76)
        let isCalibrated = analytics.showWeeklyEstimates
        let maxValue = max(0.001, isCalibrated ? (selected.compactMap(\.weeklyEquivalent).max() ?? 1) : Double(selected.map { $0.tokens.total }.max() ?? 1))
        let gap: CGFloat = rangeDays == 7 ? 12 : 2
        let barWidth = max(3, (chart.width - CGFloat(selected.count - 1) * gap) / CGFloat(selected.count))
        let formatter = DateFormatter()
        formatter.dateFormat = rangeDays == 7 ? "E" : "d"
        formatter.locale = Locale(identifier: "zh_CN")
        for (index, bucket) in selected.enumerated() {
            let value = isCalibrated ? (bucket.weeklyEquivalent ?? 0) : Double(bucket.tokens.total)
            let height = value <= 0 ? 2 : max(4, chart.height * CGFloat(value / maxValue))
            let x = chart.minX + CGFloat(index) * (barWidth + gap)
            let rect = NSRect(x: x, y: chart.maxY - height, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: min(3, barWidth / 2), yRadius: 3)
            AlfredTheme.accent.withAlphaComponent(0.86).setFill()
            path.fill()
            let hitRect = NSRect(x: x - gap / 2, y: chart.minY, width: barWidth + gap, height: chart.height + 18)
            barHitRegions.append((hitRect, bucket))
            if rangeDays == 7 || index % 5 == 0 || index == selected.count - 1 {
                drawText(formatter.string(from: bucket.date), x: x - 4, y: chart.maxY + 4, width: barWidth + 8, font: AlfredTheme.font(ofSize: 8), color: AlfredTheme.ink.withAlphaComponent(0.55), alignment: .center)
            }
        }
        if let hoveredBucket {
            drawHoverCard(bucket: hoveredBucket, chart: chart)
        }
    }

    private func drawHoverCard(bucket: DailyUsageBucket, chart: NSRect) {
        let rows = bucket.topConversations.count
        let height = CGFloat(66 + rows * 20)
        let width: CGFloat = 286
        let hoveredOnLeft = barHitRegions.first { $0.1.date == bucket.date }?.0.midX ?? 0 < bounds.midX
        let x: CGFloat = hoveredOnLeft ? bounds.width - width - 18 : 18
        let rect = NSRect(x: x, y: chart.minY - 48, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let shadow = NSShadow()
        shadow.shadowColor = AlfredTheme.ink.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: 2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        AlfredTheme.surface.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        AlfredTheme.ink.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawText(Self.fullDate(bucket.date), x: rect.minX + 12, y: rect.minY + 10, width: 110, font: AlfredTheme.font(ofSize: 11, weight: .bold))
        drawText("\(Self.week(analytics.showWeeklyEstimates ? bucket.weeklyEquivalent : nil)) · \(Self.tokens(bucket.tokens.total))", x: rect.minX + 116, y: rect.minY + 10, width: width - 128, font: AlfredTheme.font(ofSize: 10, weight: .semibold), alignment: .right)
        if bucket.topConversations.isEmpty {
            drawText("当日没有本机任务记录", x: rect.minX + 12, y: rect.minY + 38, width: width - 24, font: AlfredTheme.font(ofSize: 10), color: AlfredTheme.ink.withAlphaComponent(0.58))
            return
        }
        drawText("当日消耗最高的对话", x: rect.minX + 12, y: rect.minY + 36, width: width - 24, font: AlfredTheme.font(ofSize: 9, weight: .medium), color: AlfredTheme.ink.withAlphaComponent(0.52))
        for (index, conversation) in bucket.topConversations.enumerated() {
            let rowY = rect.minY + 53 + CGFloat(index) * 20
            drawText("\(index + 1). \(conversation.title)", x: rect.minX + 12, y: rowY, width: 160, font: AlfredTheme.font(ofSize: 10, weight: .medium))
            drawText("\(Self.week(analytics.showWeeklyEstimates ? conversation.weeklyEquivalent : nil)) · \(Self.tokens(conversation.tokens.total))", x: rect.minX + 170, y: rowY, width: width - 182, font: AlfredTheme.font(ofSize: 9, weight: .medium), alignment: .right)
        }
    }

    private func rebuildNativeRows() {
        for rows in [taskRows, recordRows] { rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() } }
        for task in analytics.recentTasks.prefix(8) {
            let title = AlfredActionButton(task.title) { [weak self] in self?.onOpenThread?(task.conversationID) }
            title.isBordered = false; title.alignment = .left; title.toolTip = task.title; title.lineBreakMode = .byTruncatingTail
            let when = task.completedAt.map(Self.shortTime) ?? "统计中"
            let detail = AlfredTextField.label("\(when) · \(Self.tokens(task.tokens.total))")
            detail.font = AlfredTheme.font(ofSize: 9); detail.textColor = AlfredTheme.muted; detail.alignment = .right
            let row = NSStackView(views: [title, detail]); row.orientation = .horizontal; row.spacing = 8
            taskRows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: taskRows.widthAnchor).isActive = true
            title.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.55).isActive = true
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        if analytics.recentTasks.isEmpty { taskRows.addArrangedSubview(AlfredTextField.label("暂无本机任务记录")) }
        let records: [(String, String, String?, Int64)] = [
            ("最高单次", analytics.highestTask?.title ?? "暂无", analytics.highestTask?.conversationID, analytics.highestTask?.tokens.total ?? 0),
            ("最高对话", analytics.highestConversationTitle ?? "暂无", analytics.highestConversationID, analytics.highestConversationTokens.total)]
        for record in records {
            let button = AlfredActionButton("\(record.0) · \(record.1)") { [weak self] in if let id = record.2 { self?.onOpenThread?(id) } }
            button.isBordered = false; button.alignment = .left; button.font = AlfredTheme.font(ofSize: 10); button.attributedTitle = AlfredTheme.text(button.title, font: button.font!, color: AlfredTheme.ink); button.toolTip = record.1; button.lineBreakMode = .byTruncatingTail
            let detail = AlfredTextField.label(Self.tokens(record.3)); detail.font = AlfredTheme.font(ofSize: 9); detail.textColor = AlfredTheme.muted
            let row = NSStackView(views: [button, detail]); row.orientation = .horizontal; row.spacing = 8
            recordRows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: recordRows.widthAnchor).isActive = true
            button.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.72).isActive = true
        }
    }

    private func drawCalibration(y: CGFloat) {
        drawText("换算关系", x: 20, y: y, width: 90, font: AlfredTheme.font(ofSize: 11, weight: .bold))
        let relation: String
        if analytics.showWeeklyEstimates, let tokens = analytics.weeklyCapacityTokens {
            relation = "1周额度 ≈ \(Self.tokens(Int64(tokens)))"
        } else {
            relation = "待收集额度变化样本"
        }
        drawText(relation, x: 105, y: y, width: 333, font: AlfredTheme.font(ofSize: 10, weight: .semibold), alignment: .right)
        drawText(analytics.quality.description, x: 20, y: y + 24, width: 418, font: AlfredTheme.font(ofSize: 10), color: AlfredTheme.muted, height: 44)
    }

    private func divider(y: CGFloat) {
        AlfredTheme.ink.withAlphaComponent(0.08).setFill()
        NSRect(x: 20, y: y, width: bounds.width - 40, height: 1).fill()
    }

    private func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor = AlfredTheme.ink, alignment: NSTextAlignment = .left, height: CGFloat = 20) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = height > 20 ? .byWordWrapping : .byTruncatingTail
        let text = NSMutableAttributedString(attributedString: AlfredTheme.text(text, font: font, color: color))
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        text.draw(in: NSRect(x: x, y: y, width: width, height: height))
    }

    private static func tokens(_ value: Int64) -> String {
        let amount = Double(value)
        if amount >= 1_000_000_000 { return String(format: "%.2fB tok", amount / 1_000_000_000) }
        if amount >= 1_000_000 { return String(format: "%.1fM tok", amount / 1_000_000) }
        if amount >= 1_000 { return String(format: "%.1fK tok", amount / 1_000) }
        return "\(value) tok"
    }

    private static func week(_ value: Double?) -> String {
        guard let value else { return "待校准" }
        if value >= 1 { return String(format: "≈%.2f周", value) }
        return String(format: "≈%.1f%%周", value * 100)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

final class QuotaPanelViewController: NSViewController {
    private let contentView = QuotaPanelContentView(frame: NSRect(x: 0, y: 0, width: 460, height: 781))
    private let pages = NSSegmentedControl(labels: ["概览", "用量", "管家", "设置"], trackingMode: .selectOne, target: nil, action: nil)
    private var pageViews: [NSView] = []
    private var lastQuotaFetchedAt: Date?
    private var quotaLoading = false
    private var quotaErrorMessage: String?
    private let defaults: UserDefaults
    private let appearanceControl = NSSegmentedControl(labels: ["跟随系统", "浅色", "深色"], trackingMode: .selectOne, target: nil, action: nil)
    private var navigationGlass: AlfredNavigationGlass?
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    let assistantBoard = AssistantBoardView()
    private let paceView = QuotaPaceView()
    private let paceLabel = AlfredTextField.label("周额度节奏待计算", wrapping: true)
    private let agendaLabel = AlfredTextField.label("日历与提醒事项尚未连接", wrapping: true)
    private lazy var inboxShortcut = makeButton("待处理 0", #selector(inboxTapped), symbol: "bell.badge")
    var onOpenThread: ((String) -> Void)? { didSet { contentView.onOpenThread = onOpenThread } }
    private let activityLabel = AlfredTextField.label("Codex 待命中", wrapping: true)
    private let quotaValue = AlfredTextField.label("—")
    private let resetLabel = AlfredTextField.label("正在读取账户周额度")
    private let todayValue = AlfredTextField.label("—")
    private let estimateLabel = AlfredTextField.label("本机日志用量正在读取", wrapping: true)
    private let updatedLabel = AlfredTextField.label("正在读取 Codex 额度…", wrapping: true)
    private let notificationFeedback = AlfredTextField.label("累计输入活跃30分钟提醒；闲置和睡眠时暂停", wrapping: true)
    private lazy var refreshButton = makeButton("刷新", #selector(refreshTapped), symbol: "arrow.clockwise")
    private lazy var petButton = NSButton(checkboxWithTitle: "显示线条小狗", target: self, action: #selector(petTapped))
    private lazy var desktopButton = NSButton(checkboxWithTitle: "显示实时桌面贴片（备选）", target: self, action: #selector(desktopTapped))
    private lazy var reminderButton = NSButton(checkboxWithTitle: "起身提醒", target: self, action: #selector(reminderTapped))
    private lazy var reminderShortcut = makeButton("距提醒 30m", #selector(reminderTapped), symbol: "figure.walk")
    private lazy var returnButton = makeButton("返回 Codex", #selector(returnTapped), symbol: "arrow.up.forward.app")
    var onRefresh: (() -> Void)?
    var onPetToggle: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onDesktopToggle: (() -> Void)?
    var onDesktopReset: (() -> Void)?
    var onReminderToggle: (() -> Void)?
    var onQuit: (() -> Void)?
    var onTestNotification: (() -> Void)?
    var onNotificationSettings: (() -> Void)?
    var onOpenCodex: (() -> Void)?

    override func loadView() {
        let effect = AlfredPopoverBackground(frame: NSRect(x: 0, y: 0, width: 460, height: 560))
        view = effect
        preferredContentSize = effect.frame.size
        NSLayoutConstraint.activate([effect.widthAnchor.constraint(equalToConstant: 460), effect.heightAnchor.constraint(equalToConstant: 560)])

        let logo = NSImageView(image: AlfredTheme.bat(size: NSSize(width: 42, height: 28)))
        let title = label("ALFRED", size: 20, weight: .bold, color: AlfredTheme.accent)
        let subtitle = label("少爷，一切尽在掌握。", size: 11, color: AlfredTheme.muted)
        let identity = column([title, subtitle], spacing: 2)
        let header = NSStackView(views: [logo, identity, NSView(), refreshButton])
        header.orientation = .horizontal; header.spacing = 12
        pages.selectedSegment = 0; pages.target = self; pages.action = #selector(pageChanged)
        pages.segmentStyle = .rounded
        pages.font = AlfredTheme.font(ofSize: 13)
        pages.setAccessibilityLabel("Alfred 页面")

        activityLabel.font = AlfredTheme.font(ofSize: 14, weight: .medium)
        activityLabel.maximumNumberOfLines = 3
        quotaValue.font = AlfredTheme.font(ofSize: 36, weight: .bold)
        quotaValue.textColor = AlfredTheme.accent
        todayValue.font = AlfredTheme.font(ofSize: 23, weight: .semibold)
        [resetLabel, estimateLabel, updatedLabel, notificationFeedback, paceLabel, agendaLabel].forEach {
            $0.font = AlfredTheme.font(ofSize: 12); $0.textColor = AlfredTheme.muted
        }
        paceView.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let shortcuts = NSStackView(views: [returnButton, inboxShortcut])
        shortcuts.orientation = .horizontal; shortcuts.spacing = 10
        let overview = column([
            card("当前任务", [activityLabel]),
            card("下一场日程 · 优先待办", [agendaLabel]),
            card("周额度 · 剩余", [quotaValue, paceView, resetLabel, paceLabel, label("金色向右＝剩余 · 暖灰向左＝周期进度\n铜橙＝超用差额 · 柔金斜纹＝富余差额", size: 10, color: AlfredTheme.muted)]),
            card("今天 · 本机用量", [todayValue, estimateLabel]),
            shortcuts, reminderShortcut, updatedLabel
        ], spacing: 14)
        appearanceControl.selectedSegment = ["system", "light", "dark"].firstIndex(of: defaults.string(forKey: "Alfred.appearance") ?? "system") ?? 0
        appearanceControl.target = self; appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.setAccessibilityLabel("外观模式")
        appearanceControl.font = AlfredTheme.font(ofSize: 12)
        let settings = column([
            card("外观", [appearanceControl, label("Comic Sans MS · 中文宋体 · 原生玻璃导航", size: 11, color: AlfredTheme.muted),
                desktopButton, makeButton("恢复桌贴位置", #selector(desktopResetTapped), symbol: "rectangle.on.rectangle"),
                label("原生小组件：桌面右键→编辑小组件→Alfred，选择大号横向组件。添加后可关闭这个备用贴片。\n原生组件由系统安排刷新；贴片跟随 Alfred 实时更新，退出 Alfred 时消失。", size: 12, color: AlfredTheme.muted)]),
            card("管家服务", [petButton, reminderButton,
                label("输入活跃累计30分钟提醒；闲置、睡眠时暂停。", size: 12, color: AlfredTheme.muted)]),
            card("通知", [notificationFeedback,
                NSStackView(views: [makeButton("测试通知", #selector(testTapped), symbol: "bell"),
                                   makeButton("通知设置", #selector(settingsTapped), symbol: "gearshape")])]),
            card("Touch Bar", [label("短按 Alfred 打开 Your dot；额度再次短按关闭，打开时刷新。", size: 12),
                label("短按状态依次回看最近五个任务；× 收起，刷新可重新显示。", size: 12, color: AlfredTheme.muted)]),
            label("额度每5分钟更新，任务状态每5秒更新。", size: 12, color: AlfredTheme.muted),
            makeButton("退出 Alfred", #selector(quitTapped), symbol: "power")
        ], spacing: 16)
        let overviewScroll = scroll(overview)
        let usageScroll = NSScrollView()
        usageScroll.drawsBackground = false; usageScroll.hasVerticalScroller = true
        usageScroll.autohidesScrollers = true; usageScroll.documentView = contentView
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([contentView.widthAnchor.constraint(equalToConstant: 460), contentView.heightAnchor.constraint(equalToConstant: 781)])
        pageViews = [overviewScroll, usageScroll, scroll(assistantBoard), scroll(settings)]
        let glass = AlfredNavigationGlass(); navigationGlass = glass
        glass.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(glass)
        NSLayoutConstraint.activate([glass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), glass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), glass.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), glass.heightAnchor.constraint(equalToConstant: 108)])
        for element in [header, pages] + pageViews {
            element.translatesAutoresizingMaskIntoConstraints = false
            if element === header || element === pages { glass.content.addSubview(element) } else { view.addSubview(element) }
        }
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 42), logo.heightAnchor.constraint(equalToConstant: 28),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), header.heightAnchor.constraint(equalToConstant: 46),
            pages.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            pages.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            pages.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), pages.heightAnchor.constraint(equalToConstant: 28)
        ])
        for page in pageViews {
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: view.leadingAnchor), page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                page.topAnchor.constraint(equalTo: pages.bottomAnchor, constant: 14),
                page.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
            ])
        }
        applyAppearance()
        pageChanged()
    }

    // Developer-only offscreen rendering: uses the real views, never opens a main app window.
    func exportPreviews(to folder: URL) throws {
        _ = view
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = appearanceControl.selectedSegment
        for (mode, index) in [("light", 1), ("dark", 2)] {
            appearanceControl.selectedSegment = index; applyAppearance()
            let destination = folder.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (index, name) in ["overview", "usage", "assistant", "settings"].enumerated() {
                pages.selectedSegment = index; pageChanged(); view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
                if index == 0, let scroll = pageViews[0] as? NSScrollView {
                    let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("overview-bottom.png"))
                    showOverviewPage()
                    precondition(abs(scroll.contentView.bounds.origin.y) < 0.1)
                }
            }
            pages.selectedSegment = 2; pageChanged()
            if let scroll = pageViews[2] as? NSScrollView {
                let height = scroll.documentView?.frame.height ?? 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView); view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("assistant-bottom.png"))
                }
            }
        }
        appearanceControl.selectedSegment = original; applyAppearance()
        pages.selectedSegment = 0; pageChanged()
    }
    var interfaceDiagnostics: [String: Any] {
        _ = view
        return ["appearanceMode": ["system", "light", "dark"][appearanceControl.selectedSegment],
                "effectiveAppearance": view.effectiveAppearance.name.rawValue,
                "nativeNavigationGlass": navigationGlass?.usesNativeGlass ?? false,
                "latinFont": AlfredTheme.font(ofSize: 12).fontName, "chineseFont": NSFont(name: "STSongti-SC-Regular", size: 12)?.fontName ?? "fallback",
                "weeklyOnly": true, "panelWidth": view.bounds.width, "panelHeight": view.bounds.height,
                "usageDocumentHeight": contentView.frame.height, "copyMenu": "复制文本"]
    }

    func overviewLayoutDiagnostics() -> [[String: Any]] {
        view.layoutSubtreeIfNeeded()
        var fields: [[String: Any]] = []
        func visit(_ child: NSView) {
            if let label = child as? AlfredTextField {
                fields.append(["text": label.stringValue, "width": label.frame.width, "height": label.frame.height,
                               "intrinsicHeight": label.intrinsicContentSize.height, "hidden": label.isHidden,
                               "ambiguous": label.hasAmbiguousLayout])
            }
            child.subviews.forEach(visit)
        }
        visit(pageViews[0])
        return fields
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = AlfredTheme.ink) -> NSTextField {
        let field = AlfredTextField.label(text, wrapping: true)
        field.font = AlfredTheme.font(ofSize: size, weight: weight); field.textColor = color
        return field
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for child in views { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func card(_ title: String, _ children: [NSView]) -> NSView {
        let card = AlfredCardView()
        let stack = column([label(title, size: 11, weight: .semibold, color: AlfredTheme.muted)] + children, spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 13), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13)
        ])
        return card
    }
    private func scroll(_ document: NSView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let container = FlippedStackContainer(); scroll.documentView = container
        document.translatesAutoresizingMaskIntoConstraints = false; container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(document)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20), document.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            document.topAnchor.constraint(equalTo: container.topAnchor), document.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return scroll
    }
    func update(snapshot: QuotaSnapshot) {
        _ = view; contentView.update(snapshot: snapshot)
        lastQuotaFetchedAt = snapshot.fetchedAt; quotaLoading = false; quotaErrorMessage = nil
        if let weekly = snapshot.weekly {
            quotaValue.stringValue = "\(Int(weekly.remainingPercent.rounded()))%"
            paceView.remaining = weekly.remainingPercent
            resetLabel.stringValue = "重置时间 · \(QuotaRowView.format(date: weekly.resetDate))"
        } else { quotaValue.stringValue = "—"; paceView.remaining = nil; resetLabel.stringValue = "账户暂未提供周额度" }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        updatedLabel.stringValue = "更新于 \(formatter.string(from: snapshot.fetchedAt))"
    }
    func update(activity: CodexActivitySnapshot) {
        _ = view; contentView.update(activity: activity)
        activityLabel.stringValue = activity.displayText; activityLabel.toolTip = activity.displayText
    }
    func update(analytics: UsageAnalyticsSnapshot) {
        _ = view; contentView.update(analytics: analytics)
        let tokens = Double(analytics.today.tokens.total)
        todayValue.stringValue = tokens >= 1_000_000 ? String(format: "%.2fM token", tokens / 1_000_000) : String(format: "%.1fK token", tokens / 1_000)
        estimateLabel.stringValue = analytics.showWeeklyEstimates ? "本机 token 统计 · 周占比估算请见「用量」" : "本机 token 统计 · 用量详情见「用量」"
    }
    func updateAssistant(notices: [AssistantNotice], pace: QuotaPace?, brief: String, agenda: String, butlerStatus: String) {
        _ = view
        refreshDataStatus()
        paceView.pace = pace; paceLabel.stringValue = pace?.description ?? "节奏待计算 · 等待周额度或重置时间"
        agendaLabel.stringValue = agenda
        inboxShortcut.title = "待处理 \(notices.count)"
        assistantBoard.update(notices: notices, brief: brief, agenda: agenda, butlerStatus: butlerStatus)
    }
    @objc private func inboxTapped() { pages.selectedSegment = 2; pageChanged() }
    func showAssistantPage() { _ = view; inboxTapped() }
    func showOverviewPage() {
        _ = view; pages.selectedSegment = 0; pageChanged()
        if let scroll = pageViews[0] as? NSScrollView {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    func update(petVisible: Bool) { _ = view; petButton.state = petVisible ? .on : .off }
    func setLoading(keepingExistingData: Bool) { _ = view; quotaLoading = true; contentView.setLoading(keepingExistingData: keepingExistingData); updatedLabel.stringValue = keepingExistingData ? "正在刷新，旧数据继续显示…" : "正在读取 Codex 额度…" }
    func show(error: Error) { _ = view; quotaLoading = false; quotaErrorMessage = error.localizedDescription; contentView.show(error: error); refreshDataStatus(); updatedLabel.toolTip = error.localizedDescription }
    private func refreshDataStatus() {
        guard !quotaLoading else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        let time = lastQuotaFetchedAt.map { formatter.string(from: $0) } ?? "尚未获取"
        if let error = quotaErrorMessage { updatedLabel.stringValue = "更新失败 · \(time)\n\(error)" }
        else if let date = lastQuotaFetchedAt, Date().timeIntervalSince(date) > 15 * 60 { updatedLabel.stringValue = "额度数据已过期 · 最后更新 \(time)" }
    }
    func update(reminder state: BreakReminderState) {
        _ = view; reminderButton.state = state.isEnabled ? .on : .off
        let title: String
        if !state.isEnabled { title = "起身提醒已关" }
        else if state.authorization == .denied { title = "提醒未授权" }
        else if state.authorization == .unknown { title = "提醒待授权" }
        else if state.pending { title = "该起身了 · 请确认活动" }
        else if let until = state.snoozedUntil { title = "已稍后 · \(max(1, Int(ceil(until.timeIntervalSinceNow / 60))))m" }
        else { title = "距提醒 \(state.remainingMinutes)m" + (state.isPaused ? " · 暂停" : "") }
        reminderShortcut.title = title
        if state.authorization == .denied {
            notificationFeedback.stringValue = "请在通知设置中允许 Alfred 发送通知。"
        } else if state.authorization == .unknown {
            notificationFeedback.stringValue = "通知授权尚未确认；开启提醒或测试通知可申请授权。"
        } else {
            notificationFeedback.stringValue = state.diagnostic ?? (state.isPaused ? "提醒暂停中：闲置、睡眠或会话未活跃。" : "通知已授权。少爷，记得偶尔起身活动。")
        }
    }
    private func makeButton(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; button.font = AlfredTheme.font(ofSize: 12, weight: .medium)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); button.imagePosition = .imageLeading }
        button.toolTip = title
        return button
    }
    @objc private func appearanceChanged() {
        defaults.set(["system", "light", "dark"][appearanceControl.selectedSegment], forKey: "Alfred.appearance")
        applyAppearance()
        onAppearanceChange?()
    }
    private func applyAppearance() {
        view.appearance = appearanceControl.selectedSegment == 0 ? nil : NSAppearance(named: appearanceControl.selectedSegment == 1 ? .aqua : .darkAqua)
        view.needsDisplay = true
        contentView.needsDisplay = true
        view.layoutSubtreeIfNeeded()
    }
    @objc private func pageChanged() { for (i, page) in pageViews.enumerated() { page.isHidden = i != pages.selectedSegment } }
    @objc private func returnTapped() { onOpenCodex?() }
    @objc private func testTapped() { onTestNotification?() }
    @objc private func settingsTapped() { onNotificationSettings?() }
    @objc private func refreshTapped() { onRefresh?() }
    @objc private func petTapped() { onPetToggle?() }
    func updateDesktop(visible: Bool) { _ = view; desktopButton.state = visible ? .on : .off }
    @objc private func desktopTapped() { onDesktopToggle?() }
    @objc private func desktopResetTapped() { onDesktopReset?() }
    @objc private func reminderTapped() { onReminderToggle?() }
    @objc private func quitTapped() { onQuit?() }
}

private final class FlippedStackContainer: NSView { override var isFlipped: Bool { true } }

private final class AlfredPopoverBackground: NSView {
    private let tint = NSView()
    override var allowsVibrancy: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let material = NSVisualEffectView(frame: bounds)
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.autoresizingMask = [.width, .height]; addSubview(material)
        tint.frame = bounds; tint.autoresizingMask = [.width, .height]; tint.wantsLayer = true; addSubview(tint)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateTint), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateTint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func updateTint() {
        let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.88
        effectiveAppearance.performAsCurrentDrawingAppearance { tint.layer?.backgroundColor = AlfredTheme.surface.withAlphaComponent(opacity).cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }
}
private final class AlfredQuotaProgress: NSView {
    var doubleValue: Double = 0 { didSet { setAccessibilityValue(doubleValue); needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        AlfredTheme.ink.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let percent = max(0, min(100, doubleValue))
        (percent < 20 ? NSColor.systemRed : AlfredTheme.accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * percent / 100, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}
