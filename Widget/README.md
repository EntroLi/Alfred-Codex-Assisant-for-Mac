# Alfred 原生桌面小组件

WidgetKit 横向 `systemExtraLarge`（4×2），最低 macOS 14，随 Alfred 一起构建。入口为 `AlfredDesktopWidget.swift`，模型与视图复用 `Sources/CodexQuotaBar/DesktopWidgetSnapshot.swift`、`DesktopWidgetView.swift`。

构建使用 `-application-extension` 和 `_NSExtensionMain` 系统入口；先签名扩展，再签名主应用，不能通过外层 `--deep` 重签抹去子扩展权限。

主应用将现有显示数据原子写入 `~/Library/Application Support/CodexQuotaBar/native-widget-v1.json`，扩展保持沙箱，只允许该文件只读。扩展不读取认证、统计、活动日志或日历，也不访问网络。用户主目录用 POSIX 查询，避免沙箱把路径重定向到扩展容器。写入最低间隔 30 秒，请求时间线刷新最低间隔 60 秒；最终显示时机由系统预算决定。旧快照会显示陈旧提示。

历史 App Group/辅助写入实验尚未端到端成功，不参与正式构建。备用桌面贴片是 Alfred 自身窗口，可拖动、随应用刷新，退出 Alfred 后消失；原生组件进入系统图库、按系统栅格放置。两者任选，避免叠放。

可在桌面右键 → 编辑小组件 → 搜索 Alfred → 添加横向组件。无法搜索时先确认主应用已安装并运行，再重新打开图库；不要重置全系统组件数据库。
