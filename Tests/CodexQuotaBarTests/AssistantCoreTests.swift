import Foundation
import Testing
@testable import CodexQuotaBar

struct AssistantCoreTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func pace(used: Double, days: Double, fresh: Bool = true) -> QuotaPace? {
        let now = start.addingTimeInterval(days * 86400)
        return QuotaPace.calculate(window: LimitWindow(title: "周", usedPercent: used, resetDate: start.addingTimeInterval(QuotaPace.week)), fetchedAt: now.addingTimeInterval(fresh ? 0 : -1000), now: now)
    }
    @Test func dayOne21PercentMeans47PercentFasterNot21PercentFaster() {
        let now = start.addingTimeInterval(86400), value = pace(used: 21, days: 1)!
        #expect(abs(value.expected - 100 / 7) < 0.001)
        #expect(abs(value.difference - 6.7142857) < 0.001)
        #expect(abs(value.relativeDifference! - 0.47) < 0.001)
        #expect(value.alertKinds(now: now).contains("fast20"))
        #expect(!value.alertKinds(now: now).contains("fast50"))
        #expect(pace(used: 22, days: 1)!.alertKinds(now: now).contains("fast50"))
    }
    @Test func staleMissingOrInitialHoursNeverInventPaceAlerts() {
        let now = start.addingTimeInterval(86400)
        #expect(pace(used: 90, days: 1, fresh: false)!.alertKinds(now: now).isEmpty)
        #expect(QuotaPace.calculate(window: LimitWindow(title: "周", usedPercent: 5, resetDate: nil), fetchedAt: now, now: now) == nil)
        #expect(QuotaPace.calculate(window: LimitWindow(title: "周", usedPercent: .nan, resetDate: now), fetchedAt: now, now: now) == nil)
        #expect(!pace(used: 5, days: 0.1)!.alertKinds(now: start.addingTimeInterval(8640)).contains("fast50"))
    }
    @Test func underuseAndLowRemainingHaveDifferentSignals() {
        #expect(pace(used: 10, days: 3)!.alertKinds(now: start.addingTimeInterval(3 * 86400)).contains("slow"))
        #expect(pace(used: 70, days: 6.5)!.alertKinds(now: start.addingTimeInterval(6.5 * 86400)).contains("reserve"))
        #expect(pace(used: 91, days: 6)!.alertKinds(now: start.addingTimeInterval(6 * 86400)).contains("low10"))
    }
    @Test func inboxSurvivesRestartAndAcknowledgementDoesNotResendSameEpisode() {
        let suite = "alfred.test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = AssistantInbox(defaults: defaults)
        let waiting = CodexActivitySnapshot(kind: .waitingApproval, sessionName: "任务甲", updatedAt: start, sessionID: "thread-a")
        inbox.observe(activities: [waiting], now: start)
        inbox.observe(activities: [waiting], now: start.addingTimeInterval(500))
        #expect(inbox.unreadCount == 1)
        let reloaded = AssistantInbox(defaults: defaults)
        #expect(reloaded.unreadCount == 1)
        reloaded.acknowledge(reloaded.notices[0].id)
        reloaded.observe(activities: [waiting], now: start.addingTimeInterval(600))
        #expect(reloaded.unreadCount == 0)
        reloaded.observe(activities: [CodexActivitySnapshot(kind: .thinking, sessionName: "任务甲", updatedAt: start.addingTimeInterval(700), sessionID: "thread-a")])
        reloaded.observe(activities: [CodexActivitySnapshot(kind: .waitingQuestion, sessionName: "任务甲", updatedAt: start.addingTimeInterval(800), sessionID: "thread-a")])
        #expect(reloaded.unreadCount == 1)
    }
    @Test func quotaAlertsDeduplicateAndEscalateInSameCycle() {
        let suite = "alfred.test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = AssistantInbox(defaults: defaults), now = start.addingTimeInterval(86400)
        inbox.observe(pace: pace(used: 21, days: 1)!, now: now)
        inbox.observe(pace: pace(used: 21, days: 1)!, now: now)
        #expect(inbox.unreadCount == 1)
        inbox.acknowledge(inbox.notices[0].id)
        inbox.observe(pace: pace(used: 21, days: 1)!, now: now)
        #expect(inbox.unreadCount == 0)
        inbox.observe(pace: pace(used: 22, days: 1)!, now: now)
        #expect(inbox.unreadCount == 1)
        #expect(inbox.notices[0].title.contains("50%"))
    }
    @Test func snoozeAndPendingSurviveSerializationWithoutCountingSleep() throws {
        var progress = BreakProgress(accumulated: 123)
        progress.due(now: start); progress.snooze(now: start)
        var restored = try JSONDecoder().decode(BreakProgress.self, from: JSONEncoder().encode(progress))
        let before = restored.resumeSnooze(now: start.addingTimeInterval(299))
        let after = restored.resumeSnooze(now: start.addingTimeInterval(300))
        #expect(!before)
        #expect(after)
        #expect(restored.pending)
        restored.completed(); #expect(restored.accumulated == 0 && !restored.pending && restored.snoozedUntil == nil)
        var clock = ActiveWorkClock(); clock.restore(1200); clock.resume(at: start)
        _ = clock.tick(at: start.addingTimeInterval(3600), idleSeconds: 0, enabled: true, allowed: true, paused: false)
        #expect(clock.accumulated == 1200)
    }
    @Test func calibrationIgnoresResetAndOldRatesAndReportsVariation() {
        let reset = start.addingTimeInterval(QuotaPace.week)
        let samples = [
            QuotaCalibrationWindow(sampledAt: start, usedPercent: 0, resetAt: reset, localCreditsAtSample: 0, rateCardVersion: CodexRateCard.version),
            QuotaCalibrationWindow(sampledAt: start.addingTimeInterval(1), usedPercent: 1, resetAt: reset, localCreditsAtSample: 1, rateCardVersion: CodexRateCard.version),
            QuotaCalibrationWindow(sampledAt: start.addingTimeInterval(2), usedPercent: 2, resetAt: reset, localCreditsAtSample: 3, rateCardVersion: CodexRateCard.version),
            QuotaCalibrationWindow(sampledAt: start.addingTimeInterval(3), usedPercent: 3, resetAt: reset.addingTimeInterval(QuotaPace.week), localCreditsAtSample: 4, rateCardVersion: CodexRateCard.version),
            QuotaCalibrationWindow(sampledAt: start.addingTimeInterval(4), usedPercent: 4, resetAt: reset, localCreditsAtSample: 100, rateCardVersion: "old")]
        let quality = CalibrationQuality.evaluate(samples: samples)
        #expect(quality.sampleCount == 4 && quality.usablePairs == 2)
        #expect(quality.relativeSpread != nil)
        #expect(!UsageAnalyticsSnapshot.empty.showWeeklyEstimates)
    }
    @Test func agendaSelectsNextTimedEventAndExplicitPriorityBeforeDueDate() {
        let meetings = [AgendaMeeting(id: "past", title: "旧会", start: start.addingTimeInterval(-60), end: start),
                        AgendaMeeting(id: "all", title: "全天", start: start, end: start.addingTimeInterval(86400), allDay: true),
                        AgendaMeeting(id: "cancel", title: "取消", start: start.addingTimeInterval(60), end: start.addingTimeInterval(120), cancelled: true),
                        AgendaMeeting(id: "next", title: "下一场", start: start.addingTimeInterval(300), end: start.addingTimeInterval(3600))]
        let todos = [AgendaTodo(id: "overdue", title: "无优先级逾期", priority: 0, due: start.addingTimeInterval(-60)),
                     AgendaTodo(id: "high", title: "高优先级", priority: 1, due: start.addingTimeInterval(3600)),
                     AgendaTodo(id: "done", title: "已完成", priority: 1, due: start, completed: true)]
        let chosen = AgendaSelection.select(meetings: meetings, todos: todos, now: start, status: "已连接")
        #expect(chosen.nextMeeting?.id == "next")
        #expect(chosen.priorityTodo?.id == "high")
    }

}
