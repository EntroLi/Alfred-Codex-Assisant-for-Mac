import Foundation
import Testing
@testable import CodexQuotaBar

struct AlfredNotificationTests {
    @Test func brandingPreservesActionRoutingWhenArtworkIsMissing() {
        let prepared = AlfredNotifications.prepare(title: "少爷，有一项操作待放行", body: "请返回对话处理。",
            kind: "attention", category: "alfred-notice", noticeID: "attention-example", resourceDirectory: nil, includeArtwork: true)
        #expect(prepared.content.title == "少爷，有一项操作待放行")
        #expect(prepared.content.subtitle == "BAT-SIGNAL · 蝙蝠信号")
        #expect(prepared.content.body == "请返回对话处理。")
        #expect(prepared.content.categoryIdentifier == "alfred-notice")
        #expect(prepared.content.userInfo["noticeID"] as? String == "attention-example")
        #expect(prepared.content.attachments.isEmpty && prepared.attachmentError != nil)
        #expect(prepared.temporaryDirectory == nil)
    }
    @Test func compactBannerKeepsActionAndRoutingWithoutRightThumbnail() {
        let task = String(repeating: "任务🦇", count: 30)
        let fullBody = "蝙蝠信号已亮：" + task + "\n请返回对话处理。此信号会保留至你确认已读。"
        let prepared = AlfredNotifications.prepare(title: "少爷，有一个问题等你回答", body: fullBody,
            kind: "attention", category: "alfred-notice", noticeID: "attention-long", resourceDirectory: nil)
        #expect(prepared.content.body == String(task.prefix(39)) + "…\n请返回对话处理，信号保留至已读。")
        #expect(prepared.content.attachments.isEmpty && prepared.attachmentError == nil)
        #expect(prepared.temporaryDirectory == nil)
        #expect(prepared.content.userInfo["noticeID"] as? String == "attention-long")
        #expect(prepared.content.categoryIdentifier == "alfred-notice")
        #expect(AlfredNotifications.bannerBody("日程正文\n请带材料。", kind: "calendar") == "日程正文\n请带材料。")
        #expect(AlfredNotifications.bannerBody("自定义提醒正文", kind: "attention") == "自定义提醒正文")
    }
    @Test func storiesCoverApprovedNoticeKindsAndRestMessagesStayActionable() {
        #expect(AlfredNotificationStory(kind: "quota").subtitle.contains("韦恩储备"))
        #expect(AlfredNotificationStory(kind: "break").subtitle.contains("蝙蝠洞"))
        #expect(AlfredNotificationStory(kind: "calendar").subtitle.contains("日程"))
        #expect(AlfredNotificationStory(kind: "todo").subtitle.contains("任务"))
        #expect(BreakReminderMessageDeck.messages.allSatisfy { ($0.title + $0.body).contains("少爷") || ($0.title + $0.body).contains("Alfred") })
        #expect(BreakReminderMessageDeck.messages.allSatisfy { $0.body.contains("起身") || $0.body.contains("离座") || $0.body.contains("站") || $0.body.contains("走") || $0.body.contains("肩") })
    }
}
