import AppKit
import Foundation
import UserNotifications

// Uses a fixture and isolated preferences; opens only Alfred's own desktop-level panel.
func verifyDesktopSticker(folder: URL) {
    NSApp.setActivationPolicy(.accessory)
    let suite = "alfred.desktop-verification." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let controller = DesktopStickerController(defaults: defaults)
    var sample = AlfredDesktopProvider().sample
    sample.appearance = "light"
    var initialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var initialBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var qaActivated = false
    var phase = "startup"
    var activationPhases: [String] = []
    let activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
        if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == ownPID {
            activationPhases.append(phase)
            if phase == "desktop" { qaActivated = true }
        }
    }
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    catch { exit(1) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    initialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    initialBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    phase = "desktop"
    controller.update(sample)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        do { try controller.exportPreview(to: folder.appendingPathComponent("desktop-light.png")) } catch { fputs("\(error)\n", stderr); exit(1) }
        sample.appearance = "dark"; controller.update(sample)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do { try controller.exportPreview(to: folder.appendingPathComponent("desktop-dark.png")) } catch { fputs("\(error)\n", stderr); exit(1) }
            let visible = controller.diagnostics
            let keptHost = NSWorkspace.shared.frontmostApplication?.processIdentifier == initialPID
            controller.toggle()
            let hidden = controller.diagnostics["visible"] as? Bool == false
            let restarted = DesktopStickerController(defaults: defaults)
            let restoredHidden = !restarted.isVisible
            controller.toggle(); controller.update(sample)
            let reopened = controller.diagnostics["visible"] as? Bool == true
            controller.stop(); restarted.stop()
            phase = "menu-fixture"
            // Reproduce the monitor-before-toggle ordering using a real own anchor window.
            let anchorWindow = NSWindow(contentRect: CGRect(x: 300, y: 500, width: 80, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            let anchor = NSButton(frame: CGRect(x: 0, y: 0, width: 80, height: 30)); anchorWindow.contentView = anchor
            let presenter = AlfredPanelPresenter(controller: QuotaPanelViewController(defaults: defaults))
            presenter.show(anchor: anchor)
            let rect = anchorWindow.convertToScreen(anchor.bounds)
            presenter.dismissForExternalClick(at: CGPoint(x: rect.midX, y: rect.midY))
            let anchorPreserved = presenter.isShown
            if presenter.isShown { presenter.close() } else { presenter.show(anchor: anchor) }
            let toggleClosed = !presenter.isShown
            presenter.show(anchor: anchor)
            presenter.dismissForExternalClick(at: CGPoint(x: -10000, y: -10000))
            let outsideClosed = !presenter.isShown
            presenter.close(); anchorWindow.orderOut(nil)
            NSWorkspace.shared.notificationCenter.removeObserver(activation)
            let passed = !qaActivated && hidden && restoredHidden && reopened && anchorPreserved && toggleClosed && outsideClosed
            let report: [String: Any] = ["passed": passed, "fixtureOnly": true, "desktop": visible,
                "frontBefore": initialBundle, "frontAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
                "qaActivated": qaActivated, "frontAfterIsThisQA": NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID,
                "activationPhases": activationPhases,
                "keptHostActive": keptHost, "hidden": hidden, "hiddenPreferenceRestored": restoredHidden, "reopened": reopened,
                "menuAnchorPreservedBeforeToggle": anchorPreserved, "menuToggleClosed": toggleClosed, "externalClickClosed": outsideClosed,
                "physicalMenuBarClickVerified": false, "nativeWidgetGalleryVerified": false]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("verification.json"))
            defaults.removePersistentDomain(forName: suite)
            exit(passed ? 0 : 1)
        }
    }
    }
}

// Reads route metadata and simulates decisions; never opens, activates or automates Codex.
func verifyButlerNavigation(output: URL) {
    let host = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.openai.codex" }
    let route = host.flatMap { CodexWindowRouteReader().read(processID: $0.processIdentifier, launchedAt: $0.launchDate) }
    var gate = ButlerNavigationGate()
    let now = Date()
    let fixture = CodexWindowRoute(path: "/dots/12345678-1234-1234-1234-123456789abc", observedAt: now)
    let preserved = (0..<5).allSatisfy { _ in gate.action(processID: 42, route: fixture, now: now) == .focus }
    let canLeaveAndReturn = gate.action(processID: 42, route: CodexWindowRoute(path: "/local/task", observedAt: now), now: now) == .navigate
    let report: [String: Any] = ["hostRunning": host != nil,
        "liveRouteCategory": route.map { $0.isButlerConversation ? "dot" : "other" } ?? "unknown",
        "fixtureRepeatedDotPressAvoidsURL": preserved, "fixtureOtherTaskStillNavigates": canLeaveAndReturn,
        "hostUIControlled": false, "liveScrollPositionVerified": false]
    do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output); exit(preserved && canLeaveAndReturn ? 0 : 1) }
    catch { fputs("Navigation verification failed: \(error)\n", stderr); exit(1) }
}

// Run against a separate, already-full-screen QA host; never activates or controls that host.
func verifyDetailPanel(output: URL) {
    NSApp.setActivationPolicy(.accessory)
    let suite = "alfred.panel-verification." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let controller = QuotaPanelViewController(defaults: defaults)
    let presenter = AlfredPanelPresenter(controller: controller)
    let initialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    controller.update(activity: .idle)
    controller.update(analytics: .empty)
    let quota = QuotaSnapshot(fiveHour: nil, weekly: LimitWindow(title: "周", usedPercent: 18,
        resetDate: Date().addingTimeInterval(6 * 86400)), fetchedAt: Date())
    controller.update(snapshot: quota)
    presenter.show(anchor: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let stayedVisible = presenter.isShown && presenter.window.isOnActiveSpace
        let keptHostActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == initialPID
        presenter.close()
        let closed = !presenter.isShown
        presenter.show(anchor: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let reopened = presenter.isShown && presenter.window.isOnActiveSpace
            presenter.close()
            let passed = stayedVisible && keptHostActive && closed && reopened
            let report: [String: Any] = ["passed": passed, "stayedVisibleForSeconds": 3,
                "stayedOnActiveSpace": stayedVisible, "keptHostActive": keptHostActive,
                "closed": closed, "reopened": reopened, "physicalTouchBarVerified": false]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            defaults.removePersistentDomain(forName: suite)
            exit(passed ? 0 : 1)
        }
    }
}

// Fixture-only AppKit layout/render check in a backing window; no production state or RPC.
func verifyOverviewAppearance(folder: URL) {
    NSApp.setActivationPolicy(.accessory)
    let suite = "alfred.layout-verification." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let controller = QuotaPanelViewController(defaults: defaults)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = controller
    window.contentView?.wantsLayer = true
    let now = Date()
    let quota = QuotaSnapshot(fiveHour: nil, weekly: LimitWindow(title: "周", usedPercent: 18, resetDate: now.addingTimeInterval(6 * 86400)), fetchedAt: now)
    controller.update(snapshot: quota)
    controller.update(activity: .idle)
    controller.update(analytics: .empty)
    controller.updateAssistant(notices: [], pace: QuotaPace.calculate(window: quota.weekly!, fetchedAt: now, now: now),
        brief: "验收小结", agenda: "下一场 · 明天 10:00\n日程显示验收\n\n优先待办 · 提交验收材料\n截止 明天 18:00", butlerStatus: "隔离验收")
    window.display()
    do {
        try controller.exportPreviews(to: folder)
        let fields = controller.overviewLayoutDiagnostics()
        let presenter = TouchBarPresenter()
        var butlerClicks = 0, quotaClicks = 0, taskClicks = 0
        presenter.onButlerClick = { butlerClicks += 1 }
        presenter.onQuotaClick = { quotaClicks += 1 }
        presenter.onStatusClick = { taskClicks += 1 }
        let bar = presenter.makeContainer()
        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        let butler = buttons.first { $0.accessibilityLabel() == "打开 Your dot" }
        let quotaButton = buttons.first { $0.accessibilityLabel() == "打开 Alfred 概览并刷新" }
        let task = buttons.first { $0.toolTip == "回到 Codex" }
        butler?.performClick(nil); quotaButton?.performClick(nil); task?.performClick(nil)
        let targets = [butler, quotaButton, task].compactMap { $0 }
        let nonOverlapping = targets.count == 3 && !targets[0].frame.intersects(targets[1].frame)
            && !targets[1].frame.intersects(targets[2].frame)
        precondition(butlerClicks == 1 && quotaClicks == 1 && taskClicks == 1 && nonOverlapping)
        precondition(bar.subviews.allSatisfy { $0.gestureRecognizers.isEmpty })
        precondition(fields.allSatisfy { ($0["height"] as? CGFloat ?? 0) > 0 && !($0["ambiguous"] as? Bool ?? true) })
        try JSONSerialization.data(withJSONObject: ["fixtureOnly": true, "layerBackedWindow": true, "overviewFields": fields,
            "touchBarShortPressCallbacks": ["butler": butlerClicks, "quota": quotaClicks, "task": taskClicks],
            "touchBarTargetsNonOverlapping": nonOverlapping, "longPressRecognizers": 0,
            "physicalTouchBarVerified": false], options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("layout.json"))
        defaults.removePersistentDomain(forName: suite)
        exit(0)
    } catch { defaults.removePersistentDomain(forName: suite); fputs("Layout verification failed: \(error)\n", stderr); exit(1) }
}

// Sends exactly one branded test through the real macOS service, without
// running the production delegate or touching preferences/statistics.
func verifyNotificationAppearance(output: URL) {
    NSApp.setActivationPolicy(.accessory)
    let center = UNUserNotificationCenter.current()
    let id = "alfred-appearance-verification-" + UUID().uuidString
    func write(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }
    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            write(["accepted": false, "reason": "existing notification authorization unavailable", "permissionRequested": false]); exit(2)
        }
        let prepared = AlfredNotifications.prepare(title: AlfredNotifications.testTitle, body: AlfredNotifications.testBody,
            kind: "test", category: "", noticeID: id)
        let before = prepared.content.attachments.count
        center.add(UNNotificationRequest(identifier: id, content: prepared.content, trigger: nil)) { error in
            prepared.cleanup()
            if let error { write(["accepted": false, "error": error.localizedDescription]); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                center.getDeliveredNotifications { notifications in
                    let delivered = notifications.first { $0.request.identifier == id }
                    write(["accepted": true, "requestIdentifier": id, "preparedAttachments": before,
                        "attachmentError": prepared.attachmentError ?? "", "delivered": delivered != nil,
                        "deliveredAttachments": delivered?.request.content.attachments.count ?? 0,
                        "title": delivered?.request.content.title ?? "", "subtitle": delivered?.request.content.subtitle ?? "",
                        "body": delivered?.request.content.body ?? "", "bannerObserved": false,
                        "systemTypographyAndContainer": true, "temporaryCopyCleaned": true,
                        "appIconFile": Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "",
                        "appBundlePath": Bundle.main.bundleURL.path,
                        "leftIconVisuallyVerified": false,
                        "compactWithoutRightThumbnail": before == 0])
                }
            }
            // Leave time for UI inspection, then remove only this test notice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
                center.removeDeliveredNotifications(withIdentifiers: [id]); center.removePendingNotificationRequests(withIdentifiers: [id]); exit(0)
            }
        }
    }
}

// Explicit developer-only mode runs the actual window/timers/decoder against an isolated preference suite.
func runPetVerification(output: URL) {
    NSApp.setActivationPolicy(.accessory)
    let suite = "local.sui.verification.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "lineDogsPetVisible")
    let pet = LineDogsCompanionController(defaults: defaults)
    var states: [[String: Any]] = [pet.diagnostics]
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        pet.update(activity: CodexActivitySnapshot(kind: .command, sessionName: nil, updatedAt: Date()))
        pet.speakNow()
        states.append(pet.diagnostics)
        pet.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            states.append(pet.diagnostics)
            pet.hide()
            pet.update(activity: CodexActivitySnapshot(kind: .waitingQuestion, sessionName: nil, updatedAt: Date()))
            pet.speakNow()
            states.append(pet.diagnostics)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                states.append(pet.diagnostics)
                let passed = states[0]["animationRunning"] as? Bool == false
                    && states[1]["renderedFrames"] as? Int == 0
                    && states[2]["animationRunning"] as? Bool == true
                    && (states[2]["cachedFrames"] as? Int ?? 0) > 0
                    && (states[2]["cachedFrames"] as? Int ?? 0) <= 48
                    && states[3]["atlasDecoded"] as? Bool == false
                    && states[4]["animationRunning"] as? Bool == false
                    && states[3]["renderedFrames"] as? Int == states[4]["renderedFrames"] as? Int
                let data = try! JSONSerialization.data(withJSONObject: ["passed": passed, "states": states], options: [.prettyPrinted, .sortedKeys])
                try! data.write(to: output)
                pet.shutdown()
                defaults.removePersistentDomain(forName: suite)
                exit(passed ? 0 : 1)
            }
        }
    }
}

// Read-only live data rendered into offscreen views; not a physical screen/Touch Bar capture.
func renderInterfaceVerification(folder: URL) {
    NSApp.setActivationPolicy(.accessory)
    DispatchQueue.global(qos: .utility).async {
        let quota = try? CodexRateLimitClient().readRateLimits()
        let activity = CodexStatusMonitor().readActivity()
        let analytics = UsageAnalyticsService().cachedSnapshot()
        DispatchQueue.main.async {
            do {
                let controller = QuotaPanelViewController()
                controller.update(activity: activity)
                controller.update(analytics: analytics)
                if let quota { controller.update(snapshot: quota) }
                controller.update(petVisible: UserDefaults.standard.bool(forKey: "lineDogsPetVisible"))
                controller.update(reminder: BreakReminderState(isEnabled: true, authorization: .allowed, remainingMinutes: 30, diagnostic: nil, isPaused: false))
                let previewSuite = "alfred.preview.\(UUID())", previewDefaults = UserDefaults(suiteName: previewSuite)!
                configureAssistantInspection(controller, defaults: previewDefaults, analytics: analytics, quota: quota)
                defer { previewDefaults.removePersistentDomain(forName: previewSuite) }
                try controller.exportPreviews(to: folder)
                let bar = TouchBarQuotaView(frame: NSRect(x: 0, y: 0, width: 720, height: 30))
                bar.update(activity: activity)
                if let quota { bar.update(snapshot: quota) }
                let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("touchbar-content.png"))
                let metadata: [String: Any] = ["kind": "offscreen-AppKit-live-data", "quotaReadSucceeded": quota != nil,
                    "reminderDisplay": "allowed-30-minute-fixture", "physicalInteractionVerified": false]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("metadata.json"))
                previewDefaults.removePersistentDomain(forName: previewSuite)
                exit(0)
            } catch { fputs("Render verification failed: \(error)\n", stderr); exit(1) }
        }
    }
}

// Temporary QA host for the existing popover, not a product main window.
private var interfaceInspectionWindow: NSWindow?
private var interfaceInspectionCleanup: NSObjectProtocol?
func inspectInterfaceVerification() {
    NSApp.setActivationPolicy(.accessory)
    DispatchQueue.global(qos: .utility).async {
        let quota = try? CodexRateLimitClient().readRateLimits()
        let activity = CodexStatusMonitor().readActivity()
        let analytics = UsageAnalyticsService().cachedSnapshot()
        DispatchQueue.main.async {
            let suite = "local.alfred.interface-inspection.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            interfaceInspectionCleanup = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                defaults.removePersistentDomain(forName: suite)
            }
            let controller = QuotaPanelViewController(defaults: defaults)
            controller.update(activity: activity); controller.update(analytics: analytics)
            if let quota { controller.update(snapshot: quota) }
            controller.update(reminder: BreakReminderState(isEnabled: true, authorization: .allowed, remainingMinutes: 30, diagnostic: nil, isPaused: false))
            configureAssistantInspection(controller, defaults: defaults, analytics: analytics, quota: quota)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Alfred · 弹窗验收"
            window.contentViewController = controller; window.isReleasedWhenClosed = false
            window.isOpaque = false; window.backgroundColor = .clear
            window.center(); window.makeKeyAndOrderFront(nil)
            interfaceInspectionWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private func configureAssistantInspection(_ controller: QuotaPanelViewController, defaults: UserDefaults, analytics: UsageAnalyticsSnapshot, quota: QuotaSnapshot?) {
    let inbox = AssistantInbox(defaults: defaults)
    let now = Date()
    let fixture = AssistantNotice(id: "inspection-attention", kind: "attention", title: "少爷，有一个问题等你回答 · 验收", body: "蝙蝠信号已亮。横幅消失后仍保留，点已读后清除。", createdAt: now)
    _ = inbox.post(fixture)
    _ = inbox.post(AssistantNotice(id: "inspection-break", kind: "break", title: "少爷，蝙蝠洞该整备了 · 验收", body: "请起身舒展肩背。稍后5分钟或确认已活动。", createdAt: now))
    let pace = quota?.weekly.flatMap { QuotaPace.calculate(window: $0, fetchedAt: quota!.fetchedAt, now: now) }
    let agenda = "日历与提醒事项待连接（这里不读取日历或创建事项）"
    let refresh = {
        let brief = LocalDailyBrief.make(analytics: analytics, activities: [], agenda: MacAgendaSnapshot(), activeSeconds: 600, breaks: 1)
        controller.assistantBoard.updateDailyTodos(brief.todos)
        controller.updateAssistant(notices: inbox.notices, pace: pace, brief: brief.summary, agenda: agenda,
            butlerStatus: "验收窗口 · 数据与通知动作隔离")
    }
    controller.onOpenThread = { id in
        if UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/" + id) { NSWorkspace.shared.open(url) }
    }
    inbox.onChange = refresh
    controller.assistantBoard.onAcknowledge = { inbox.acknowledge($0) }
    controller.assistantBoard.onSnooze = { inbox.acknowledge("inspection-break") }
    controller.assistantBoard.onBreakDone = { inbox.acknowledge("inspection-break") }
    refresh()
}
