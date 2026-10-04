import Foundation
import AppKit
import Testing
@testable import CodexQuotaBar

struct DesktopWidgetTests {
    @Test func startupPreservesQuotaAndAgendaButRealDeniedResultReplacesThem() {
        let now = Date()
        let cached = DesktopWidgetSnapshot(updatedAt: now, quotaFetchedAt: now, remaining: 80,
            resetDate: now.addingTimeInterval(6 * 86400), meeting: "会议", todo: "任务", todayTokens: "12M")
        var incoming = DesktopWidgetSnapshot(updatedAt: now, unread: 2)
        incoming.meeting = "日历待授权"; incoming.todo = "提醒事项待授权"
        let startup = incoming.preservingLoadingFields(from: cached, quotaReady: false, agendaReady: false, activityReady: false, analyticsReady: false)
        #expect(startup.remaining == 80 && startup.meeting == "会议" && startup.todo == "任务")
        #expect(startup.unread == 2 && startup.todayTokens == "12M")
        let read = incoming.preservingLoadingFields(from: cached, quotaReady: true, agendaReady: true, activityReady: true, analyticsReady: true)
        #expect(read.remaining == nil && read.meeting == "日历待授权")
    }
    @Test func combinedGaugeMeasuresOverspendAndSurplusOnOneTrack() {
        let fast = DualQuotaGauge(remaining: 75, expectedUsed: 14.6)
        #expect(abs(fast.naturalStartFraction! - 0.854) < 0.0001)
        #expect(abs(fast.difference! - 10.4) < 0.0001)
        #expect(fast.varianceRange?.lowerBound == 0.75)
        let slow = DualQuotaGauge(remaining: 90, expectedUsed: 14.6)
        #expect(abs(slow.difference! + 4.6) < 0.0001)
        #expect(slow.varianceRange?.upperBound == 0.9)
        #expect(DualQuotaGauge(remaining: 180, expectedUsed: .nan).remaining == 100)
        #expect(DualQuotaGauge(remaining: .nan, expectedUsed: nil).naturalStartFraction == nil)
    }
    @Test func cycleAndStalenessFollowSourceDatesRatherThanStatusUpdates() {
        let now = Date()
        let cached = DesktopWidgetSnapshot(updatedAt: now, quotaFetchedAt: now.addingTimeInterval(-1000), remaining: 80,
            resetDate: now.addingTimeInterval(6 * 86400))
        #expect(cached.isStale(at: now))
        #expect(abs(cached.naturalUsed(at: now)! - 100 / 7) < 0.0001)
        #expect(cached.naturalUsed(at: now.addingTimeInterval(7 * 86400)) == nil)
    }
    @Test func desktopPlacementRecoversRemovedScreenAndKeepsTwoToOneAspect() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        for rect in [DesktopStickerPlacement.initial(in: screen), DesktopStickerPlacement.fit(CGRect(x: 5000, y: 5000, width: 1200, height: 600), in: screen)] {
            #expect(screen.contains(rect))
            #expect(rect.width == 2 * rect.height)
        }
    }
    @Test func menuAnchorClickBelongsToToggleAndExternalClickDismisses() {
        let panel = CGRect(x: 100, y: 100, width: 460, height: 560), anchor = CGRect(x: 300, y: 700, width: 70, height: 24)
        #expect(!AlfredPanelPresenter.shouldDismiss(point: CGPoint(x: 330, y: 711), panel: panel, anchor: anchor))
        #expect(!AlfredPanelPresenter.shouldDismiss(point: CGPoint(x: 200, y: 300), panel: panel, anchor: anchor))
        #expect(AlfredPanelPresenter.shouldDismiss(point: CGPoint(x: 600, y: 700), panel: panel, anchor: anchor))
        #expect(AlfredPanelPresenter.shouldDismiss(point: CGPoint(x: 330, y: 711), panel: panel, anchor: nil))
    }
    @Test func sharedSnapshotRejectsCorruptionFutureSchemaAndInvalidQuota() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("snapshot.json")
        var snapshot = DesktopWidgetSnapshot(updatedAt: Date(), remaining: 80)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        #expect(DesktopWidgetSnapshot.read(from: url) == snapshot)
        snapshot.schema = 2
        try JSONEncoder().encode(snapshot).write(to: url)
        #expect(DesktopWidgetSnapshot.read(from: url) == nil)
        snapshot.schema = 1; snapshot.remaining = 120
        try JSONEncoder().encode(snapshot).write(to: url)
        #expect(DesktopWidgetSnapshot.read(from: url) == nil)
        try Data("unfinished JSON".utf8).write(to: url)
        #expect(DesktopWidgetSnapshot.read(from: url) == nil)
    }
    @Test func oldOrExpiredSnapshotDoesNotPretendToBeCurrentQuota() {
        let now = Date(), value = DesktopWidgetSnapshot(updatedAt: now, remaining: 80, resetDate: now.addingTimeInterval(30))
        #expect(value.quotaText(at: now) == "80%")
        #expect(value.quotaText(at: now.addingTimeInterval(31)) == "—")
        #expect(value.isStale(at: now.addingTimeInterval(901)))
        var newer = value; newer.updatedAt = now.addingTimeInterval(5)
        #expect(newer.sameContent(as: value))
        newer.unread = 1
        #expect(!newer.sameContent(as: value))
    }
    @Test func widgetOnlyAcceptsOwnFixedNavigationRoutes() {
        for action in ["overview", "butler", "task", "calendar", "reminders", "refresh"] {
            #expect(DesktopWidgetSnapshot.action(for: DesktopWidgetSnapshot.actionURL(action)) == action)
        }
        for text in ["codex://dots", "alfred-batcave://task?url=https://example.com", "alfred-batcave://task/other", "alfred-batcave://unknown"] {
            #expect(DesktopWidgetSnapshot.action(for: URL(string: text)! ) == nil)
        }
    }
}
