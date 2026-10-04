import AppKit
import EventKit
import Foundation

enum AgendaAccess: String {
    case notAsked, allowed, denied, restricted, writeOnly
    var label: String {
        switch self {
        case .notAsked: return "待授权"
        case .allowed: return "已连接"
        case .denied: return "未获授权"
        case .restricted: return "系统限制"
        case .writeOnly: return "需要读取授权"
        }
    }
}

struct MacAgendaSnapshot {
    var eventsAccess: AgendaAccess = .notAsked
    var remindersAccess: AgendaAccess = .notAsked
    var selection = AgendaSelection(status: "尚未读取")
    var fetchedAt: Date?
    var error: String?
    var eventCount = 0
    var reminderCount = 0
    var meetings: [AgendaMeeting] = []
    var todos: [AgendaTodo] = []
    var description: String {
        let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN"); date.dateFormat = "M/d E HH:mm"
        let meeting: String
        if eventsAccess != .allowed { meeting = "下一场日程 · 日历" + eventsAccess.label }
        else if let value = selection.nextMeeting { meeting = "下一场 · " + date.string(from: value.start) + "\n" + value.title }
        else { meeting = error == nil ? "下一场 · 未来30天暂无定时日程" : "下一场 · 暂无法确认" }
        let todo: String
        if remindersAccess != .allowed { todo = "优先待办 · 提醒事项" + remindersAccess.label }
        else if let value = selection.priorityTodo {
            if !value.dueHasTime { date.dateFormat = "M/d E" }
            todo = "优先待办 · " + value.title + (value.due.map { "\n截止 " + date.string(from: $0) } ?? "")
        } else { todo = error == nil ? "优先待办 · 暂无未完成事项" : "优先待办 · 暂无法确认" }
        return meeting + "\n\n" + todo + (error.map { "\n读取异常：" + $0 } ?? "")
    }
    var diagnostics: [String: Any] {
        ["eventsAccess": eventsAccess.rawValue, "remindersAccess": remindersAccess.rawValue,
         "fetchedAt": fetchedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
         "eventCount": eventCount, "incompleteReminderCount": reminderCount,
         "hasNextMeeting": selection.nextMeeting != nil, "hasPriorityTodo": selection.priorityTodo != nil,
         "error": error ?? "", "readOnly": true]
    }
}

/// EventKit only; no database reads, saves, deletes or remote calendar requests.
final class MacAgendaService {
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "local.alfred.agenda", qos: .utility)
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var reading = false
    private var queuedRefresh = false
    private var requesting = false
    private var activeRead: UUID?
    var onChange: ((MacAgendaSnapshot) -> Void)?
    private(set) var snapshot = MacAgendaSnapshot()

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 5
        refresh()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
    }
    private static func access(_ type: EKEntityType) -> AgendaAccess {
        let value = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14.0, *) {
            if value == .fullAccess { return .allowed }
            if value == .writeOnly { return .writeOnly }
        }
        switch value {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .denied
        }
    }
    /// Called only by the user's connect action or the explicitly approved first deployment flag.
    func requestAccess() {
        precondition(Thread.isMainThread)
        guard !requesting else { return }; requesting = true
        let afterEvents: (Bool, Error?) -> Void = { [weak self] _, eventError in
            DispatchQueue.main.async {
                guard let self else { return }
                let afterReminders: (Bool, Error?) -> Void = { [weak self] _, reminderError in
                    DispatchQueue.main.async {
                        guard let self else { return }; self.requesting = false
                        self.snapshot.error = (reminderError ?? eventError)?.localizedDescription
                        self.refresh()
                    }
                }
                if Self.access(.reminder) == .notAsked {
                    if #available(macOS 14.0, *) { self.store.requestFullAccessToReminders(completion: afterReminders) }
                    else { self.store.requestAccess(to: .reminder, completion: afterReminders) }
                } else { afterReminders(false, nil) }
            }
        }
        if Self.access(.event) == .notAsked || Self.access(.event) == .writeOnly {
            if #available(macOS 14.0, *) { store.requestFullAccessToEvents(completion: afterEvents) }
            else { store.requestAccess(to: .event, completion: afterEvents) }
        } else { afterEvents(false, nil) }
    }
    func refresh() {
        precondition(Thread.isMainThread)
        guard !reading else { queuedRefresh = true; return }; reading = true
        let eventAccess = Self.access(.event), reminderAccess = Self.access(.reminder)
        let request = UUID(); activeRead = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, reading, activeRead == request else { return }
            activeRead = nil; reading = false; queuedRefresh = false
            snapshot.eventsAccess = eventAccess; snapshot.remindersAccess = reminderAccess
            snapshot.error = "日程读取超时，请稍后重新读取。"
            onChange?(snapshot)
        }
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            var meetings: [AgendaMeeting] = []
            if eventAccess == .allowed {
                let predicate = store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: now.addingTimeInterval(30 * 86400), calendars: nil)
                meetings = store.events(matching: predicate).map { event in
                    AgendaMeeting(id: event.calendarItemIdentifier, title: event.title ?? "未命名日程", start: event.startDate,
                        end: event.endDate, allDay: event.isAllDay,
                        cancelled: event.status == .canceled || event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true)
                }
            }
            let frozenMeetings = meetings
            let finish: ([AgendaTodo], String?) -> Void = { [weak self] todos, error in
                let value = MacAgendaSnapshot(eventsAccess: eventAccess, remindersAccess: reminderAccess,
                    selection: AgendaSelection.select(meetings: frozenMeetings, todos: todos, now: now, status: "Mac日历／提醒事项 · 只读"),
                    fetchedAt: now, error: error, eventCount: frozenMeetings.count, reminderCount: todos.count,
                    meetings: frozenMeetings, todos: todos)
                DispatchQueue.main.async { [weak self] in
                    guard let self, activeRead == request else { return }
                    activeRead = nil; snapshot = value; reading = false; onChange?(value)
                    if queuedRefresh { queuedRefresh = false; refresh() }
                }
            }
            if reminderAccess == .allowed {
                let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
                store.fetchReminders(matching: predicate) { [weak self] values in
                    self?.queue.async {
                        let todos = (values ?? []).map { reminder in
                            let components = reminder.dueDateComponents
                            var calendar = components?.calendar ?? Calendar.current
                            if let zone = components?.timeZone { calendar.timeZone = zone }
                            return AgendaTodo(id: reminder.calendarItemIdentifier, title: reminder.title ?? "未命名事项",
                                priority: reminder.priority, due: components.flatMap { calendar.date(from: $0) }, completed: reminder.isCompleted,
                                dueHasTime: components?.hour != nil)
                        }
                        finish(todos, values == nil ? "提醒事项暂未返回数据，请重新读取。" : nil)
                    }
                }
            } else { finish([], nil) }
        }
    }
}

enum AgendaReminderPolicy {
    static func notices(for selection: AgendaSelection, now: Date = Date(), calendar: Calendar = .current) -> [AssistantNotice] {
        var result: [AssistantNotice] = []
        let formatter = DateFormatter(); formatter.dateFormat = "M/d HH:mm"; formatter.timeZone = calendar.timeZone
        if let meeting = selection.nextMeeting, !meeting.allDay, !meeting.cancelled,
           meeting.start >= now, meeting.start.timeIntervalSince(now) <= 10 * 60 {
            result.append(AssistantNotice(id: "meeting-\(meeting.id)-\(Int64(meeting.start.timeIntervalSince1970))", kind: "calendar",
                title: "少爷，下一场日程即将开始", body: "哥谭日程：\(formatter.string(from: meeting.start))\n\(meeting.title)\n请准备出席。", createdAt: now))
        }
        if let todo = selection.priorityTodo, !todo.completed {
            let day = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
            let deadlineSoon = todo.dueHasTime && todo.due.map { $0 >= now && $0.timeIntervalSince(now) <= 600 } == true
            if !todo.dueHasTime { formatter.dateFormat = "M/d" }
            let noticeID = deadlineSoon ? "todo-deadline-\(todo.id)-\(Int64(todo.due!.timeIntervalSince1970))" : "todo-\(todo.id)-\(day)"
            result.append(AssistantNotice(id: noticeID, kind: "todo", title: deadlineSoon ? "少爷，优先任务即将到期" : "少爷，优先任务已就位",
                body: todo.title + (todo.due.map { "\n截止 " + formatter.string(from: $0) } ?? "\n暂无截止时间") + "\n请按你的安排处理；Alfred 会保留这条提醒。", createdAt: now))
        }
        return result
    }
}
