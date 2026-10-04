import Foundation
import Testing
@testable import CodexQuotaBar

struct AgendaReminderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func missingPermissionOrReadFailureDoesNotClaimEmptyAgenda() {
        #expect(MacAgendaSnapshot().description.contains("待授权"))
        #expect(!MacAgendaSnapshot().description.contains("暂无未完成"))
        let value = MacAgendaSnapshot(eventsAccess: .allowed, remindersAccess: .denied, error: "超时")
        #expect(value.description.contains("暂无法确认"))
        #expect(value.description.contains("未获授权"))
        #expect(!value.description.contains("暂无定时"))
    }
    @Test func meetingReminderHasTenMinuteWindowAndOccurrenceIdentity() {
        let event = AgendaMeeting(id: "recurring", title: "组会", start: now.addingTimeInterval(600), end: now.addingTimeInterval(3600))
        let chosen = AgendaSelection(nextMeeting: event, status: "已连接")
        let due = AgendaReminderPolicy.notices(for: chosen, now: now)
        #expect(due.count == 1 && due[0].kind == "calendar")
        #expect(AgendaReminderPolicy.notices(for: chosen, now: now.addingTimeInterval(-1)).isEmpty)
        #expect(AgendaReminderPolicy.notices(for: chosen, now: now.addingTimeInterval(601)).isEmpty)
        let next = AgendaSelection(nextMeeting: AgendaMeeting(id: "recurring", title: "组会", start: now.addingTimeInterval(86400), end: now.addingTimeInterval(90000)), status: "已连接")
        #expect(AgendaReminderPolicy.notices(for: next, now: now.addingTimeInterval(85800))[0].id != due[0].id)
    }
    @Test func priorityTaskReminderDeduplicatesWithinDayButReturnsNextDay() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let selection = AgendaSelection(priorityTodo: AgendaTodo(id: "task", title: "交材料", priority: 1, due: nil), status: "已连接")
        let first = AgendaReminderPolicy.notices(for: selection, now: calendar.startOfDay(for: now), calendar: calendar)[0]
        let repeated = AgendaReminderPolicy.notices(for: selection, now: calendar.startOfDay(for: now).addingTimeInterval(600), calendar: calendar)[0]
        let tomorrow = AgendaReminderPolicy.notices(for: selection, now: calendar.startOfDay(for: now).addingTimeInterval(86400), calendar: calendar)[0]
        #expect(first.id == repeated.id && first.id != tomorrow.id)
        let suite = "alfred.agenda.test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = AssistantInbox(defaults: defaults)
        let inserted = inbox.post(first), insertedAgain = inbox.post(repeated)
        #expect(inserted && !insertedAgain && inbox.unreadCount == 1)
    }
    @Test func timedDeadlineEscalatesAndDateOnlyDoesNotInventMidnight() {
        var todo = AgendaTodo(id: "t", title: "提交", priority: 1, due: now.addingTimeInterval(600))
        var selection = AgendaSelection(priorityTodo: todo, status: "已连接")
        #expect(AgendaReminderPolicy.notices(for: selection, now: now)[0].title.contains("即将到期"))
        #expect(!AgendaReminderPolicy.notices(for: selection, now: now.addingTimeInterval(-1))[0].title.contains("即将到期"))
        todo.dueHasTime = false; selection.priorityTodo = todo
        #expect(!AgendaReminderPolicy.notices(for: selection, now: now)[0].title.contains("即将到期"))
        let snapshot = MacAgendaSnapshot(eventsAccess: .allowed, remindersAccess: .allowed, selection: selection)
        #expect(!snapshot.description.contains(":"))
    }
}
