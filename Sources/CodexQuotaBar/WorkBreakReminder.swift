import AppKit
import CoreGraphics
import Foundation
import UserNotifications
import OSLog

struct BreakReminderMessage: Equatable {
    let title: String
    let body: String
}

struct BreakReminderMessageDeck {
    static let messages = [
        BreakReminderMessage(title: "少爷，蝙蝠洞该整备了", body: "少爷，巡夜可以继续，肩背先休息。请起身走两步，喝口水，再回来接手任务。"),
        BreakReminderMessage(title: "蝙蝠装甲需要舒展", body: "少爷，装甲很结实，肩颈也需要照顾。请离座伸展两分钟。"),
        BreakReminderMessage(title: "Alfred 的离席建议", body: "少爷，请起身去窗边看看。哥谭的任务等你回来继续。"),
        BreakReminderMessage(title: "巡夜也有中场休息", body: "半小时已到，少爷。起身走一圈，让双腿接替手指活动一下。"),
        BreakReminderMessage(title: "蝙蝠洞补给时间", body: "少爷，去接杯水，顺便舒展肩背。你的下一段专注值得好好准备。"),
        BreakReminderMessage(title: "战衣维护，请稍候", body: "少爷，请起身两分钟。把肩膀放松，把僵硬留在椅子上。"),
        BreakReminderMessage(title: "给下一项任务留口气", body: "Alfred 建议：先走几步，再回来处理下一项。思路和腰背都需要留白。"),
        BreakReminderMessage(title: "少爷，换一个站姿", body: "你已认真工作半小时。现在请站起来，让蝙蝠洞的椅子休息一会儿。"),
        BreakReminderMessage(title: "哥谭暂时交给我", body: "少爷，离座走两步吧。任务仍在这里，身体也值得你的照顾。"),
        BreakReminderMessage(title: "蝙蝠洞的温柔警报", body: "少爷，肩背需要一次更新：站立、伸展、走动。完成后点「已活动」开始下一轮。"),
        BreakReminderMessage(title: "巡夜前，先松松肩", body: "少爷，请看向远处，舒展肩颈。回来后，我们继续把事情安排妥当。"),
        BreakReminderMessage(title: "少爷，该离席片刻了", body: "不必远行，绕桌走一圈就好。Alfred 会保留这条提醒，等你确认已活动。"),
        BreakReminderMessage(title: "下一轮专注前的整备", body: "少爷，起身喝口水吧。休息完成后点「已活动」，再开始下一段工作。"),
        BreakReminderMessage(title: "蝙蝠信号，起身版本", body: "少爷，这次信号是提醒你照顾肩背。请离座活动两分钟。"),
        BreakReminderMessage(title: "Alfred 请求两分钟", body: "哥谭可以等两分钟，腰背不必一直等。少爷，请起身走走。")
    ]

    private(set) var lastIndex: Int?

    mutating func next(randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }) -> BreakReminderMessage {
        guard Self.messages.count > 1 else { return Self.messages[0] }
        var index = randomIndex(Self.messages.count)
        if index == lastIndex {
            index = (index + 1) % Self.messages.count
        }
        lastIndex = index
        return Self.messages[index]
    }
}

enum BreakReminderAuthorization {
    case unknown
    case allowed
    case denied
}

struct BreakReminderState {
    let isEnabled: Bool
    let authorization: BreakReminderAuthorization
    let remainingMinutes: Int
    let diagnostic: String?
    let isPaused: Bool
    var pending = false
    var snoozedUntil: Date? = nil
}

// Input activity is a work approximation, never posture detection.
struct ActiveWorkClock {
    private(set) var accumulated: TimeInterval = 0
    private var lastTick: Date?
    private(set) var lastContribution: TimeInterval = 0
    mutating func restore(_ value: TimeInterval) { accumulated = max(0, min(WorkBreakReminder.interval, value)) }
    mutating func resume(at date: Date) { lastTick = date }
    mutating func reset(at date: Date) { accumulated = 0; lastTick = date }
    mutating func tick(at now: Date, idleSeconds: TimeInterval, enabled: Bool, allowed: Bool, paused: Bool) -> Bool {
        lastContribution = 0
        defer { lastTick = now }
        guard let previous = lastTick, enabled, allowed, !paused else { return false }
        let elapsed = now.timeIntervalSince(previous)
        // Discard sleep/stall gaps and only count the active part before the idle threshold.
        guard elapsed > 0, elapsed <= 30, idleSeconds.isFinite, idleSeconds >= 0 else { return false }
        lastContribution = max(0, min(elapsed, WorkBreakReminder.activeIdleThreshold - idleSeconds + elapsed))
        accumulated += lastContribution
        if accumulated >= WorkBreakReminder.interval { accumulated = 0; return true }
        return false
    }
}

final class WorkBreakReminder: NSObject, UNUserNotificationCenterDelegate {
    static let interval: TimeInterval = 30 * 60
    static let activeIdleThreshold: TimeInterval = 5 * 60

    var onStateChange: ((BreakReminderState) -> Void)?
    var onBreakDue: (() -> Void)?
    var onBreakHandled: (() -> Void)?
    var onNoticeAction: ((String, String) -> Void)?
    private var progress = BreakProgress()
    private var activityClock = ActiveWorkClock()
    var activeSecondsToday: TimeInterval { dailyTotals().0 }
    var breaksToday: Int { dailyTotals().1 }

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var timer: Timer?
    private var clock = ActiveWorkClock()
    private var sleeping = false
    private var sessionActive = true
    private var lastDiagnostic: String?
    private var authorizationQuery = 0
    private var lastSettingsCheck = Date.distantPast
    private let logger = Logger(subsystem: "local.codex.quota-bar", category: "reminder")
    private var authorization: BreakReminderAuthorization = .unknown
    private var deck = BreakReminderMessageDeck()
    private let enabledKey = "workBreakReminder.enabled"

    var isEnabled: Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        super.init()
        progress = defaults.data(forKey: "Alfred.breakProgress").flatMap { try? JSONDecoder().decode(BreakProgress.self, from: $0) } ?? BreakProgress()
        clock.restore(progress.accumulated)
        center.delegate = self
    }

    func start() {
        clock.resume(at: Date()); activityClock.resume(at: Date())
        let snooze = UNNotificationAction(identifier: "break-snooze", title: "稍后5分钟", options: [])
        let done = UNNotificationAction(identifier: "break-done", title: "已活动", options: [])
        let open = UNNotificationAction(identifier: "notice-open", title: "查看信号", options: [.foreground])
        let read = UNNotificationAction(identifier: "notice-read", title: "已读", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "alfred-break", actions: [snooze, done], intentIdentifiers: []), UNNotificationCategory(identifier: "alfred-notice", actions: [open, read], intentIdentifiers: [])])
        observeWake()
        refreshAuthorization(requestIfNeeded: isEnabled)
        scheduleTimer()
        if progress.pending { onBreakDue?() }
        publishState()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func toggle() {
        let enabled = !isEnabled
        defaults.set(enabled, forKey: enabledKey)
        clock.reset(at: Date()); progress.completed(); persistProgress(); onBreakHandled?()
        if enabled {
            refreshAuthorization(requestIfNeeded: true)
        }
        publishState()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 2
    }

    private func tick(now: Date = Date()) {
        precondition(Thread.isMainThread)
        if now.timeIntervalSince(lastSettingsCheck) >= 60 { refreshAuthorization(requestIfNeeded: false) }
        let idle = Self.secondsSinceLastInput()
        _ = activityClock.tick(at: now, idleSeconds: idle, enabled: true, allowed: true, paused: sleeping || !sessionActive)
        updateDailyTotals(activeDelta: activityClock.lastContribution)
        let snoozeDue = isEnabled && authorization == .allowed && !sleeping && sessionActive && progress.resumeSnooze(now: now)
        let due = clock.tick(at: now, idleSeconds: idle, enabled: isEnabled && !progress.pending && progress.snoozedUntil == nil,
                             allowed: authorization == .allowed, paused: sleeping || !sessionActive)
        if due || snoozeDue { progress.due(now: now); onBreakDue?(); deliverReminder(test: false) }
        progress.accumulated = clock.accumulated; persistProgress()
        publishState()
    }

    func testNotification() {
        refreshAuthorization(requestIfNeeded: true) { [weak self] in
            guard let self else { return }
            guard authorization == .allowed else {
                lastDiagnostic = "通知未获授权，请在系统设置中允许Alfred通知"
                publishState()
                return
            }
            deliverReminder(test: true)
        }
    }

    private func deliverReminder(test: Bool) {
        let message = test ? BreakReminderMessage(title: AlfredNotifications.testTitle, body: AlfredNotifications.testBody) : deck.next()
        let prepared = AlfredNotifications.prepare(title: message.title, body: message.body, kind: test ? "test" : "break",
            category: test ? "" : "alfred-break", noticeID: test ? "test" : "break")
        let content = prepared.content
        center.add(UNNotificationRequest(identifier: test ? "work-break-\(UUID().uuidString)" : "alfred-work-break", content: content, trigger: nil)) { [weak self] error in
            prepared.cleanup()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let error {
                    lastDiagnostic = "通知发送失败：\(error.localizedDescription)"
                    logger.error("Notification add failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    lastDiagnostic = test ? "测试已提交给系统，请查看通知；专注模式可能延迟横幅" : "起身提醒已提交给系统"
                    if let artworkError = prepared.attachmentError { lastDiagnostic = "通知已提交；蝙蝠插图未能附加：" + artworkError }
                    logger.info("Notification accepted; test=\(test)")
                }
                publishState()
            }
        }
    }

    func refreshAuthorization(requestIfNeeded: Bool = false, completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        authorizationQuery += 1
        let query = authorizationQuery
        lastSettingsCheck = Date()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { [weak self] in
                guard let self, query == authorizationQuery else { return }
                let previous = authorization
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: authorization = .allowed
                case .denied: authorization = .denied
                case .notDetermined where requestIfNeeded:
                    center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, query == authorizationQuery else { return }
                            if let error { lastDiagnostic = "权限请求失败：\(error.localizedDescription)" }
                            refreshAuthorization(completion: completion)
                        }
                    }
                    return
                default: authorization = .unknown
                }
                if previous != authorization { lastDiagnostic = nil }
                publishState()
                completion?()
            }
        }
    }

    private func publishState() {
        let remaining = max(0, Self.interval - clock.accumulated)
        onStateChange?(BreakReminderState(
            isEnabled: isEnabled,
            authorization: authorization,
            remainingMinutes: max(1, Int(ceil(remaining / 60))),
            diagnostic: lastDiagnostic,
            isPaused: sleeping || !sessionActive || Self.secondsSinceLastInput() > Self.activeIdleThreshold,
            pending: progress.pending, snoozedUntil: progress.snoozedUntil
        ))
    }

    func snooze() {
        center.removeDeliveredNotifications(withIdentifiers: ["alfred-work-break"])
        progress.snooze(now: Date()); clock.reset(at: Date()); persistProgress(); onBreakHandled?(); publishState()
    }
    func completedBreak() {
        center.removeDeliveredNotifications(withIdentifiers: ["alfred-work-break"])
        progress.completed(); clock.reset(at: Date()); persistProgress()
        updateDailyTotals(activeDelta: 0, completed: true); onBreakHandled?(); publishState()
    }
    private func persistProgress() {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: "Alfred.breakProgress") }
    }
    private func dailyTotals() -> (TimeInterval, Int) {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard defaults.double(forKey: "Alfred.activeDay") == day else { return (0, 0) }
        return (defaults.double(forKey: "Alfred.activeSeconds"), defaults.integer(forKey: "Alfred.completedBreaks"))
    }
    private func updateDailyTotals(activeDelta: TimeInterval, completed: Bool = false) {
        let totals = dailyTotals()
        defaults.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: "Alfred.activeDay")
        defaults.set(totals.0 + activeDelta, forKey: "Alfred.activeSeconds")
        defaults.set(totals.1 + (completed ? 1 : 0), forKey: "Alfred.completedBreaks")
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let self else { return }
            switch response.actionIdentifier {
            case "break-snooze": snooze()
            case "break-done": completedBreak()
            default:
                if let id = response.notification.request.content.userInfo["noticeID"] as? String {
                    onNoticeAction?(id, response.actionIdentifier)
                }
            }
        }
    }

    private func observeWake() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(applicationActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkSettings), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func didWake() { sleeping = false; clock.resume(at: Date()); activityClock.resume(at: Date()); refreshAuthorization(); publishState() }
    @objc private func willSleep() { sleeping = true; clock.resume(at: Date()); activityClock.resume(at: Date()); publishState() }
    @objc private func sessionResigned() { sessionActive = false; clock.resume(at: Date()); activityClock.resume(at: Date()); publishState() }
    @objc private func sessionBecameActive() { sessionActive = true; didWake() }
    @objc private func applicationActivated(_ notification: Notification) {
        // Recheck on returning from System Settings even though this is an accessory app.
        refreshAuthorization()
    }
    @objc private func checkSettings() { refreshAuthorization() }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        let eventTypes: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return eventTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .greatestFiniteMagnitude
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
