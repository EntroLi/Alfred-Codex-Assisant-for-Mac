import Foundation
import Testing
@testable import CodexQuotaBar

@Suite struct LocalDailyBriefTests {
    var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 15))! }
    @Test func missingAccessNeverBecomesNoTasks() {
        let report = LocalDailyBrief.make(analytics: .empty, activities: [], agenda: MacAgendaSnapshot(), activeSeconds: 0, breaks: 0, now: now, calendar: calendar)
        #expect(report.todos.contains("日历待授权，暂无法确认"))
        #expect(report.todos.contains("提醒事项待授权，暂无法确认"))
        #expect(report.summary.contains("蝙蝠洞日报"))
        #expect(!report.todos.contains("暂无今天到期"))
    }
    @Test func dateOnlyDeadlineLastsWholeDayAndFutureHighPriorityIsIncluded() {
        let dateOnly = AgendaTodo(id: "today", title: "今天截止", priority: 0, due: calendar.startOfDay(for: now), dueHasTime: false)
        let futureHigh = AgendaTodo(id: "future", title: "重点任务", priority: 1, due: now.addingTimeInterval(3 * 86400))
        let futureLow = AgendaTodo(id: "low", title: "以后再做", priority: 9, due: now.addingTimeInterval(3 * 86400))
        let done = AgendaTodo(id: "done", title: "已完成", priority: 1, due: now, completed: true)
        let ordered = LocalDailyBrief.orderedTodos([futureHigh, futureLow, done, dateOnly], now: now, calendar: calendar)
        #expect(ordered.map(\.id) == ["today", "future"])
        let agenda = MacAgendaSnapshot(eventsAccess: .allowed, remindersAccess: .allowed, fetchedAt: now, todos: [dateOnly])
        let report = LocalDailyBrief.make(analytics: .empty, activities: [], agenda: agenda, activeSeconds: 60, breaks: 1, now: now, calendar: calendar)
        #expect(report.todos.contains("今天截止 · 10/4"))
        #expect(!report.todos.contains("已逾期"))
    }
    @Test func pendingSignalsDeduplicateAndDoNotInventProjectCompletion() {
        let activity = CodexActivitySnapshot(kind: .waitingQuestion, sessionName: "验收任务", updatedAt: now, sessionID: "thread")
        let report = LocalDailyBrief.make(analytics: .empty, activities: [activity, activity], agenda: MacAgendaSnapshot(), activeSeconds: 0, breaks: 0, now: now, calendar: calendar)
        #expect(report.summary.contains("仍有 1 个本机信号"))
        #expect(report.todos.components(separatedBy: "验收任务").count == 2)
        #expect(report.summary.contains("不代表整个项目完成"))
        #expect(report.summary.contains("时段经过不等于实际出席"))
    }
    @Test func ongoingMeetingIsShownAndCancelledMeetingIsExcluded() {
        let current = AgendaMeeting(id: "now", title: "当前会议", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60))
        let cancelled = AgendaMeeting(id: "cancel", title: "取消会议", start: now, end: now.addingTimeInterval(60), cancelled: true)
        let agenda = MacAgendaSnapshot(eventsAccess: .allowed, remindersAccess: .allowed, fetchedAt: now, error: "刷新失败", meetings: [current, cancelled])
        let report = LocalDailyBrief.make(analytics: .empty, activities: [], agenda: agenda, activeSeconds: 0, breaks: 0, now: now, calendar: calendar)
        #expect(report.todos.contains("当前时段"))
        #expect(!report.summary.contains("取消会议"))
        #expect(report.todos.contains("读取异常"))
    }
    @Test func failedReadCannotBeReportedAsAnEmptyDay() {
        let agenda = MacAgendaSnapshot(eventsAccess: .allowed, remindersAccess: .allowed, error: "刷新失败")
        let report = LocalDailyBrief.make(analytics: .empty, activities: [], agenda: agenda, activeSeconds: 0, breaks: 0, now: now, calendar: calendar)
        #expect(report.summary.contains("今日日程暂无法确认"))
        #expect(report.todos.contains("优先任务暂无法确认"))
        #expect(!report.todos.contains("已读取的提醒中暂无"))
    }
}
