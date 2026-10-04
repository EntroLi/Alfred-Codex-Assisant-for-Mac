import SwiftUI
import WidgetKit

@main struct AlfredDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DesktopWidgetSnapshot.kind, provider: AlfredDesktopProvider()) { entry in AlfredDesktopView(entry: entry) }
            .configurationDisplayName("Alfred · 蝙蝠洞桌贴")
            .description("周额度、下一场日程与优先待办。点击 Alfred 前往管家。")
            .supportedFamilies([.systemExtraLarge])
    }
}
