import SwiftUI
import WidgetKit
import OSLog

struct AlfredDesktopEntry: TimelineEntry {
    let date: Date
    let snapshot: DesktopWidgetSnapshot?
}
struct AlfredDesktopProvider: TimelineProvider {
    private func liveSnapshot() -> DesktopWidgetSnapshot? {
        let value = DesktopWidgetSnapshot.read(from: DesktopWidgetSnapshot.localCacheURL())
        Logger(subsystem: "local.codex.quota-bar.desktop", category: "snapshot").info("own-display-snapshot-loaded: \(value != nil, privacy: .public)")
        return value
    }
    func placeholder(in context: Context) -> AlfredDesktopEntry { AlfredDesktopEntry(date: Date(), snapshot: sample) }
    func getSnapshot(in context: Context, completion: @escaping (AlfredDesktopEntry) -> Void) {
        completion(AlfredDesktopEntry(date: Date(), snapshot: context.isPreview ? sample : liveSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AlfredDesktopEntry>) -> Void) {
        let now = Date(), snapshot = liveSnapshot()
        let next = now.addingTimeInterval(15 * 60)
        // A dated entry also marks old data if the app stops and the system delays the next refresh.
        completion(Timeline(entries: [AlfredDesktopEntry(date: now, snapshot: snapshot), AlfredDesktopEntry(date: next.addingTimeInterval(1), snapshot: snapshot)], policy: .after(next)))
    }
    var sample: DesktopWidgetSnapshot {
        DesktopWidgetSnapshot(updatedAt: Date(), quotaFetchedAt: Date(), remaining: 80, resetDate: Date().addingTimeInterval(5 * 86400),
            pace: "比均匀进度节省 8.6 个百分点", activity: "战术推演 · 下一项任务", meeting: "下一场会议", meetingTime: "明天 20:00", todo: "最高优先级待办", todoTime: "尚待完成", unread: 2, todayTokens: "14.82M", briefHeadline: "今日主线 · 哥谭行动安排")
    }
}

struct AlfredWidgetBat: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0.02,0.86),(0.22,0.70),(0.35,0.72),(0.40,0.92),(0.45,0.66),(0.55,0.66),(0.60,0.92),(0.65,0.72),(0.78,0.70),(0.98,0.86),(0.86,0.34),(0.76,0.48),(0.67,0.25),(0.59,0.36),(0.50,0.05),(0.41,0.36),(0.33,0.25),(0.24,0.48),(0.14,0.34)]
        var path = Path()
        for (i, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + (1 - point.1) * rect.height)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath(); return path
    }
}

struct AlfredQuotaGauge: View {
    let remaining: Double?
    let expected: Double?
    let gold: Color
    let muted: Color
    let palette: AlfredGaugePalette
    private func color(_ tone: AlfredGaugePalette.Tone) -> Color { Color(red: tone.red, green: tone.green, blue: tone.blue) }
    var body: some View {
        GeometryReader { proxy in
            let gauge = DualQuotaGauge(remaining: remaining, expectedUsed: expected)
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(muted.opacity(0.16)).frame(height: 11).offset(y: 9)
                Capsule().fill(LinearGradient(colors: [gold.opacity(0.75), gold], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * gauge.remainingFraction, height: 11).offset(y: 9)
                if let range = gauge.varianceRange, let difference = gauge.difference {
                    let zoneWidth = width * (range.upperBound-range.lowerBound)
                    ZStack {
                        RoundedRectangle(cornerRadius: 2).fill(color(difference > 0 ? palette.overuse : palette.reserve).opacity(0.30))
                        if difference < 0 { AlfredReserveHatch().stroke(color(palette.natural).opacity(0.65), lineWidth: 0.7).clipped() }
                    }.frame(width: zoneWidth, height: 11).offset(x: width * range.lowerBound, y: 9)
                }
                if let fraction = gauge.naturalStartFraction {
                    Capsule().fill(color(palette.natural)).frame(width: width * (1-fraction), height: 3).offset(x: width * fraction, y: 17)
                    AlfredWidgetBat().fill(color(palette.natural)).frame(width: 12, height: 8).offset(x: min(max(0, width*fraction-6), width-12))
                }
            }
        }.frame(height: 21)
         .accessibilityLabel("金色从左显示剩余额度，暖灰从右显示周期进度；铜橙超用，柔金斜纹富余")
    }
}

struct AlfredReserveHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: rect.minX - rect.height, through: rect.maxX + rect.height, by: 6) {
            path.move(to: CGPoint(x: x, y: rect.maxY)); path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        }
        return path
    }
}

struct AlfredDesktopView: View {
    let entry: AlfredDesktopEntry
    @Environment(\.colorScheme) private var systemScheme
    private var dark: Bool { entry.snapshot?.appearance == "dark" || (entry.snapshot?.appearance != "light" && systemScheme == .dark) }
    private var gaugePalette: AlfredGaugePalette { AlfredGaugePalette(dark: dark) }
    private func gaugeColor(_ tone: AlfredGaugePalette.Tone) -> Color { Color(red: tone.red, green: tone.green, blue: tone.blue) }
    private var ink: Color { dark ? Color(white: 0.94) : Color(white: 0.13) }
    private var muted: Color { dark ? Color(white: 0.70) : Color(white: 0.40) }
    private var gold: Color { dark ? Color(red: 0.95, green: 0.78, blue: 0.39) : Color(red: 0.48, green: 0.32, blue: 0.06) }
    private var background: Color { dark ? Color(red: 0.065, green: 0.078, blue: 0.10) : Color(red: 0.97, green: 0.96, blue: 0.93) }
    private func cn(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size) }
    private func en(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "ComicSansMS-Bold" : "ComicSansMS", size: size) }
    @ViewBuilder var body: some View {
        if #available(macOS 14.0, *) { content.containerBackground(background, for: .widget).widgetURL(DesktopWidgetSnapshot.actionURL("overview")) }
        else { content.background(background) }
    }
    #if !ALFRED_WIDGET
    var desktopBody: some View {
        content.padding(16).background(background).clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .top) {
                Capsule().fill(Color.gray.opacity(0.6)).frame(width: 30, height: 3).frame(width: 80, height: 12)
                    .overlay { DesktopStickerHandle().frame(width: 80, height: 12) }.help("拖动移动桌贴")
            }
    }
    #endif
    private var content: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 500, proxy.size.height / 250)
            dashboard.frame(width: proxy.size.width / max(scale, 0.01), height: 250).scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Link(destination: DesktopWidgetSnapshot.actionURL("butler")) {
                    HStack(spacing: 8) {
                        AlfredWidgetBat().fill(gold).frame(width: 34, height: 22)
                        Text("ALFRED").font(en(22, bold: true)).foregroundStyle(gold)
                        Text("哥谭指挥台").font(cn(9)).foregroundStyle(muted)
                    }
                }.accessibilityLabel("打开 Your dot 管家")
                Spacer(minLength: 4)
                Link(destination: DesktopWidgetSnapshot.actionURL("overview")) {
                    HStack(spacing: 4) {
                        Circle().fill((entry.snapshot?.unread ?? 0) > 0 ? Color.orange : muted).frame(width: 5, height: 5)
                        Text("待处理 \(entry.snapshot?.unread ?? 0)").font(cn(10))
                    }.foregroundStyle(ink).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(muted.opacity(0.08), in: Capsule())
                }
                Link(destination: DesktopWidgetSnapshot.actionURL("refresh")) { Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundStyle(gold) }.accessibilityLabel("打开 Alfred 并刷新")
            }.frame(height: 28)
            if let value = entry.snapshot {
                HStack(alignment: .top, spacing: 9) {
                    Link(destination: DesktopWidgetSnapshot.actionURL("overview")) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("韦恩储备 · 周额度").font(cn(10)).foregroundStyle(muted)
                                Spacer(minLength: 0)
                                if let reset = value.resetDate, reset > entry.date {
                                    Text("还有 \(Int(ceil(reset.timeIntervalSince(entry.date) / 86400))) 天").font(cn(9)).foregroundStyle(gold)
                                }
                            }
                            Text(value.quotaText(at: entry.date)).font(en(39, bold: true)).foregroundStyle(gold).minimumScaleFactor(0.7).lineLimit(1)
                            AlfredQuotaGauge(remaining: value.quotaText(at: entry.date) == "—" ? nil : value.remaining,
                                expected: value.naturalUsed(at: entry.date), gold: gold, muted: muted, palette: gaugePalette)
                            HStack {
                                Text("剩余 →").foregroundStyle(gold)
                                Spacer()
                                Text("← 周期进度").foregroundStyle(gaugeColor(gaugePalette.natural))
                            }.font(cn(8))
                            Text(value.pace).font(cn(10)).foregroundStyle(paceColor(value)).lineLimit(2)
                            Text(resetText(value)).font(cn(9)).foregroundStyle(muted).lineLimit(1)
                        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                         .background(LinearGradient(colors: [gold.opacity(0.11), gold.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
                         .overlay(RoundedRectangle(cornerRadius: 14).stroke(gold.opacity(0.15), lineWidth: 0.5))
                    }.accessibilityLabel("周额度剩余 " + value.quotaText(at: entry.date) + "，点击开关 Alfred")
                    VStack(alignment: .leading, spacing: 8) {
                        agendaCard("下一场日程", title: value.meeting, detail: value.meetingTime, symbol: "calendar", action: "calendar")
                        agendaCard("优先待办", title: value.todo, detail: value.todoTime, symbol: "checklist", action: "reminders")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxHeight: .infinity)
                HStack(spacing: 8) {
                    Link(destination: DesktopWidgetSnapshot.actionURL("task")) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(value.activity).font(cn(10, bold: true)).foregroundStyle(ink).lineLimit(2)
                            if let headline = value.briefHeadline { Text(headline).font(cn(9)).foregroundStyle(muted).lineLimit(1) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .trailing, spacing: 3) {
                        (Text("今日 ").font(cn(9)) + Text(value.todayTokens + " token").font(en(11, bold: true))).foregroundStyle(gold).lineLimit(1)
                        Text(value.isStale(at: entry.date) ? "数据待更新" : "更新 " + value.updatedAt.formatted(.dateTime.hour().minute())).font(cn(8)).foregroundStyle(muted)
                    }
                }.padding(8).background(muted.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Spacer()
                Text("少爷，蝙蝠洞正在接收数据。").font(cn(18, bold: true)).foregroundStyle(ink)
                Text("首次启动请稍候，或点击刷新打开 Alfred。").font(cn(11)).foregroundStyle(muted)
                Spacer()
            }
        }
    }
    private func paceColor(_ value: DesktopWidgetSnapshot) -> Color {
        let gauge = DualQuotaGauge(remaining: value.remaining, expectedUsed: value.naturalUsed(at: entry.date))
        guard let difference = gauge.difference else { return muted }
        return abs(difference) < 2 ? muted : gaugeColor(difference > 0 ? gaugePalette.overuse : gaugePalette.reserve)
    }
    private func resetText(_ value: DesktopWidgetSnapshot) -> String {
        if value.quotaFailed { return "读取失败 · 保留上次额度" }
        guard let reset = value.resetDate else { return "重置时间尚未读取" }
        if reset <= entry.date { return "等待新周期额度" }
        let format = DateFormatter(); format.dateFormat = "M/d HH:mm"
        return "重置 " + format.string(from: reset)
    }
    private func agendaCard(_ label: String, title: String, detail: String, symbol: String, action: String) -> some View {
        Link(destination: DesktopWidgetSnapshot.actionURL(action)) {
            VStack(alignment: .leading, spacing: 3) {
                Label(label, systemImage: symbol).font(cn(9)).foregroundStyle(gold)
                Text(title).font(cn(12, bold: true)).foregroundStyle(ink).lineLimit(2)
                Text(detail).font(cn(9)).foregroundStyle(muted).lineLimit(1)
            }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
             .background(muted.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
             .overlay(RoundedRectangle(cornerRadius: 12).stroke(muted.opacity(0.09), lineWidth: 0.5))
        }
    }
}
