import AppKit
import Testing
@testable import CodexQuotaBar

struct PanelLayoutTests {
    @Test @MainActor func longParagraphWrapsWithoutDemandingWindowWidth() {
        let field = AlfredTextField.label(String(repeating: "蝙蝠洞日报：今日任务与提醒事项需要继续处理。", count: 20), wrapping: true)
        field.font = AlfredTheme.font(ofSize: 12)
        field.setFrameSize(NSSize(width: 382, height: 20))
        let wideHeight = field.intrinsicContentSize.height
        #expect(field.intrinsicContentSize.width == NSView.noIntrinsicMetric)
        field.setFrameSize(NSSize(width: 190, height: 20))
        #expect(field.intrinsicContentSize.height > wideHeight)
    }

    @Test @MainActor func longNoticeAndDailyBriefKeepDetailPanelCompact() {
        let suite = "local.alfred.layout-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = QuotaPanelViewController(defaults: defaults)
        let presenter = AlfredPanelPresenter(controller: controller)
        let paragraph = String(repeating: "今日哥谭巡逻：任务、日历与提醒事项的长标题需要完整换行。", count: 30)
        controller.assistantBoard.updateDailyTodos(paragraph)
        controller.updateAssistant(notices: [AssistantNotice(id: "fixture", kind: "attention", title: paragraph,
            body: paragraph, createdAt: Date())], pace: nil, brief: paragraph, agenda: paragraph, butlerStatus: paragraph)
        controller.showAssistantPage()
        controller.view.layoutSubtreeIfNeeded()
        #expect(presenter.window.frame.width == 460)
        #expect(controller.view.frame.width == 460)
        #expect(controller.view.frame.height == 560)
        #expect(controller.view.fittingSize.width == 460)
    }
}
