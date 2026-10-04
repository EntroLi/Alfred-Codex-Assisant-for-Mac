import Foundation
import Darwin

/// The extension receives only this small read-only snapshot, never Codex credentials or logs.
struct DesktopWidgetSnapshot: Codable, Equatable {
    static let groupID = "group.local.codex.quota-bar"
    static let kind = "AlfredDesktop"
    var schema = 1
    var updatedAt: Date
    var quotaFetchedAt: Date?
    var remaining: Double?
    var resetDate: Date?
    var quotaFailed = false
    var pace = "周额度节奏待计算"
    var activity = "蝙蝠洞待命"
    var meeting = "日程尚未连接"
    var meetingTime = "请在 Alfred 管家页连接日历"
    var todo = "待办尚未连接"
    var todoTime = "请在 Alfred 管家页连接提醒事项"
    var unread = 0
    var todayTokens = "—"
    var appearance = "system"
    var agendaFetchedAt: Date?
    var briefHeadline: String?

    static func cacheURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("AlfredDesktop-v1.json")
    }
    static func localCacheURL() -> URL? {
        // Foundation's home directory is redirected inside an extension sandbox.
        // POSIX resolves this user's home; the extension has read access to one fixed own file only.
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support/CodexQuotaBar/native-widget-v1.json")
    }
    static func read(from url: URL?) -> DesktopWidgetSnapshot? {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1024, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1,
              value.remaining.map({ $0.isFinite && (0...100).contains($0) }) ?? true else { return nil }
        return value
    }
    func sameContent(as other: Self) -> Bool {
        var current = self; current.updatedAt = other.updatedAt
        return current == other
    }
    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(quotaFetchedAt ?? updatedAt) > 15 * 60 || (agendaFetchedAt.map { date.timeIntervalSince($0) > 15 * 60 } ?? false)
    }
    func naturalUsed(at date: Date) -> Double? {
        guard let resetDate, resetDate > date, resetDate.timeIntervalSince(date) <= 7 * 86400 else { return nil }
        return (1 - resetDate.timeIntervalSince(date) / (7 * 86400)) * 100
    }
    func preservingLoadingFields(from prior: Self?, quotaReady: Bool, agendaReady: Bool, activityReady: Bool, analyticsReady: Bool) -> Self {
        guard let prior else { return self }
        var result = self
        if !quotaReady {
            result.remaining = prior.remaining; result.resetDate = prior.resetDate; result.quotaFetchedAt = prior.quotaFetchedAt
            result.quotaFailed = prior.quotaFailed; result.pace = prior.pace
        }
        if !agendaReady {
            result.meeting = prior.meeting; result.meetingTime = prior.meetingTime
            result.todo = prior.todo; result.todoTime = prior.todoTime; result.agendaFetchedAt = prior.agendaFetchedAt
        }
        if !activityReady { result.activity = prior.activity }
        if !analyticsReady, Calendar.current.isDate(prior.updatedAt, inSameDayAs: updatedAt) {
            result.todayTokens = prior.todayTokens; result.briefHeadline = prior.briefHeadline
        }
        return result
    }
    func quotaText(at date: Date) -> String {
        guard let remaining else { return "—" }
        if let resetDate, resetDate <= date { return "—" }
        return "\(Int(remaining.rounded()))%"
    }
    static func actionURL(_ action: String) -> URL { URL(string: "alfred-batcave://" + action)! }
    static func action(for url: URL) -> String? {
        guard url.scheme == "alfred-batcave", url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let action = url.host, ["overview", "butler", "task", "calendar", "reminders", "refresh"].contains(action) else { return nil }
        return action
    }
}

/// Gold remaining quota advances from the left; blue elapsed cycle advances from the right.
struct DualQuotaGauge {
    let remaining: Double
    let expectedUsed: Double?
    init(remaining: Double?, expectedUsed: Double?) {
        self.remaining = remaining.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil } ?? 0
        self.expectedUsed = expectedUsed.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
    }
    var remainingFraction: Double { remaining / 100 }
    var naturalStartFraction: Double? { expectedUsed.map { 1 - $0 / 100 } }
    var difference: Double? { expectedUsed.map { 100 - remaining - $0 } }
    var varianceRange: ClosedRange<Double>? {
        naturalStartFraction.map { min(remainingFraction, $0)...max(remainingFraction, $0) }
    }
}

/// Shared warm neutrals keep AppKit and WidgetKit quota rendering in the Alfred palette.
struct AlfredGaugePalette {
    struct Tone { let red: Double; let green: Double; let blue: Double }
    let natural: Tone
    let overuse: Tone
    let reserve: Tone
    init(dark: Bool) {
        natural = dark ? Tone(red: 0.87, green: 0.83, blue: 0.74) : Tone(red: 0.43, green: 0.39, blue: 0.32)
        overuse = dark ? Tone(red: 0.94, green: 0.59, blue: 0.30) : Tone(red: 0.67, green: 0.32, blue: 0.12)
        reserve = dark ? Tone(red: 0.91, green: 0.78, blue: 0.51) : Tone(red: 0.55, green: 0.40, blue: 0.16)
    }
}
