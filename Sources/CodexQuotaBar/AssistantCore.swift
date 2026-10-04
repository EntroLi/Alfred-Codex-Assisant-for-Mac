import Foundation
import UserNotifications

struct QuotaPace: Equatable {
    static let week: TimeInterval = 7 * 86400
    let used: Double
    let expected: Double
    let reset: Date
    let fetchedAt: Date
    var difference: Double { used - expected }
    var relativeDifference: Double? { expected >= 100 / 28 ? difference / expected : nil }
    var remaining: Double { 100 - used }
    var cycleID: String { String(Int64(reset.timeIntervalSince1970)) }
    var description: String {
        let direction = difference >= 0 ? "多用" : "少用"
        let relative = relativeDifference.map { String(format: " · 节奏%@ %.0f%%", $0 >= 0 ? "快" : "慢", abs($0) * 100) } ?? " · 周初观察中"
        return String(format: "已用 %.1f%% · 均匀进度 %.1f%%\n%@ %.1f 个百分点%@", used, expected, direction, abs(difference), relative)
    }
    static func calculate(window: LimitWindow, fetchedAt: Date, now: Date) -> QuotaPace? {
        guard let reset = window.resetDate, window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
              now <= reset, reset.timeIntervalSince(now) <= week, fetchedAt <= now.addingTimeInterval(60) else { return nil }
        let elapsed = week - reset.timeIntervalSince(now)
        return QuotaPace(used: window.usedPercent, expected: elapsed / week * 100, reset: reset, fetchedAt: fetchedAt)
    }
    func alertKinds(now: Date) -> [String] {
        guard now.timeIntervalSince(fetchedAt) <= 15 * 60 else { return [] }
        var kinds: [String] = []
        if remaining <= 10 { kinds.append("low10") } else if remaining <= 20 { kinds.append("low20") }
        if let relativeDifference, difference >= 2 {
            if relativeDifference >= 0.5 { kinds.append("fast50") }
            else if relativeDifference >= 0.2 { kinds.append("fast20") }
        }
        if reset.timeIntervalSince(now) <= 86400, remaining >= 20 { kinds.append("reserve") }
        else if expected >= 100 / 7, difference <= -3, (relativeDifference ?? 0) <= -0.2 { kinds.append("slow") }
        return kinds
    }
}

struct AssistantNotice: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    var title: String
    var body: String
    let createdAt: Date
    var threadID: String?
    var resolved: Bool = false
}

struct AssistantNoticeArchive: Codable {
    var notices: [AssistantNotice] = []
    var notified: [String: Date] = [:]
    var attentionEpisodes: [String: String] = [:]
}

/// Persistent inbox is independent of the system's short-lived notification banner.
final class AssistantInbox {
    private(set) var archive: AssistantNoticeArchive
    private let defaults: UserDefaults
    var onChange: (() -> Void)?
    var onNotify: ((AssistantNotice) -> Void)?
    private let key = "Alfred.inbox.v1"
    var notices: [AssistantNotice] { archive.notices.sorted { $0.createdAt > $1.createdAt } }
    var unreadCount: Int { archive.notices.count }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archive = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AssistantNoticeArchive.self, from: $0) } ?? AssistantNoticeArchive()
    }
    @discardableResult func post(_ notice: AssistantNotice) -> Bool {
        guard archive.notified[notice.id] == nil else { return false }
        archive.notices.append(notice); archive.notified[notice.id] = notice.createdAt
        // Do not remove unread items. Only expire old deduplication receipts.
        archive.notified = archive.notified.filter { notice.createdAt.timeIntervalSince($0.value) < 90 * 86400 }
        save(); onNotify?(notice); return true
    }
    func acknowledge(_ id: String) { archive.notices.removeAll { $0.id == id }; save() }
    func observe(activities: [CodexActivitySnapshot], now: Date = Date()) {
        for activity in activities {
            guard let thread = activity.sessionID else { continue }
            let waiting = activity.kind.priority >= CodexActivityKind.waitingQuestion.priority
            if waiting {
                let episode = archive.attentionEpisodes[thread] ?? "attention-\(thread)-\(Int64(activity.updatedAt.timeIntervalSince1970))"
                archive.attentionEpisodes[thread] = episode
                _ = post(AssistantNotice(id: episode, kind: "attention", title: activity.kind == .waitingApproval ? "少爷，有一项操作待放行" : activity.kind == .waitingReview ? "少爷，有一份任务待审阅" : "少爷，有一个问题等你回答",
                    body: "蝙蝠信号已亮：" + (activity.sessionName ?? "Codex 对话") + "\n请返回对话处理。此信号会保留至你确认已读。", createdAt: now, threadID: thread))
            } else if let episode = archive.attentionEpisodes.removeValue(forKey: thread) {
                if let index = archive.notices.firstIndex(where: { $0.id == episode }) { archive.notices[index].resolved = true }
                save()
            }
        }
    }
    func observe(pace: QuotaPace, now: Date = Date(), calendar: Calendar = .current) {
        let day = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        for kind in pace.alertKinds(now: now) {
            let suffix = ["slow", "reserve"].contains(kind) ? "-\(day)" : ""
            let id = "quota-\(pace.cycleID)-\(kind)\(suffix)"
            if kind == "fast20", archive.notified["quota-\(pace.cycleID)-fast50"] != nil { continue }
            if kind == "low20", archive.notified["quota-\(pace.cycleID)-low10"] != nil { continue }
            let title: String
            switch kind {
            case "low10": title = "韦恩储备不足 10%"
            case "low20": title = "韦恩储备不足 20%"
            case "fast50": title = "少爷，额度节奏快了 50%"
            case "fast20": title = "少爷，额度节奏快了 20%"
            case "reserve": title = "韦恩储备即将重置"
            default: title = "储备充足，可安排下一项"
            }
            _ = post(AssistantNotice(id: id, kind: "quota", title: title, body: (kind == "reserve" || kind == "slow" ? "少爷，可安排一项有价值的工作。\n" : "少爷，请留意本周额度安排。\n") + pace.description, createdAt: now))
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(archive) { defaults.set(data, forKey: key) }
        onChange?()
    }
}

struct BreakProgress: Codable, Equatable {
    var accumulated: TimeInterval = 0
    var pending = false
    var snoozedUntil: Date?
    mutating func due(now: Date) { pending = true; snoozedUntil = nil }
    mutating func snooze(now: Date) { pending = false; snoozedUntil = now.addingTimeInterval(5 * 60) }
    mutating func completed() { accumulated = 0; pending = false; snoozedUntil = nil }
    mutating func resumeSnooze(now: Date) -> Bool {
        guard let until = snoozedUntil, now >= until else { return false }
        due(now: now); return true
    }
}

struct DailyBrief {
    static func text(analytics: UsageAnalyticsSnapshot, activeSeconds: TimeInterval, breaks: Int, agenda: String, now: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "M月d日"
        let top = analytics.dailyBuckets.last?.topConversations.map { "· \($0.title)（\(formatTokens($0.tokens.total))）" }.joined(separator: "\n") ?? ""
        return "\(formatter.string(from: now)) · 今日工作小结\n本机用量：\(formatTokens(analytics.today.tokens.total)) token\n输入活跃约 \(Int(activeSeconds / 60)) 分钟 · 已确认活动 \(breaks) 次\n\(top.isEmpty ? "今天尚无本机对话用量" : "主要对话：\n" + top)\n\n今日安排：\n\(agenda)"
    }
    static func formatTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000 { return String(format: "%.2fM", Double(tokens) / 1_000_000) }
        if tokens >= 1000 { return String(format: "%.1fK", Double(tokens) / 1000) }
        return String(tokens)
    }
}
