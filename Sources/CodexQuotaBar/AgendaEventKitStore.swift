import Foundation
import EventKit

struct AgendaCalendarInfo: Codable {
    var entity: AgendaEntity
    var sourceID: String
    var sourceTitle: String
    var calendarID: String
    var title: String
    var writable: Bool
}

struct AgendaReadRequest: Codable {
    var allVisibleSources: Bool
    var sourceIDs: [String]
    var calendarIDs: [String]
    var eventStart: String?
    var eventEnd: String?
    var includeReminders: Bool
    var timeZone: String
}

struct AgendaReadResult: Codable {
    var readAt: String
    var finishedAt: String
    var device: String
    var path = "Alfred manual EventKit; no notes/participants/alarms"
    var request: AgendaReadRequest
    var calendars: [AgendaCalendarInfo]
    var eventSegments: [[String]]
    var records: [AgendaRecord]
    var reminderScope = "All completed and incomplete reminders in the selected lists"
    var writeAuthorization = "none"
}

extension EKCalendarItem: AgendaNativeTextItem {}

final class AgendaEventKitStore: AgendaWorkflowStore {
    private lazy var store = EKEventStore()
    private let formatter = ISO8601DateFormatter()
    private let versionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()

    static func permissionStatus(_ entity: AgendaEntity) -> String {
        let value = EKEventStore.authorizationStatus(for: entity == .event ? .event : .reminder)
        if #available(macOS 14.0, *) {
            if value == .fullAccess { return "fullAccess" }
            if value == .writeOnly { return "writeOnly" }
        }
        switch value {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized-legacy"
        default: return "unknown"
        }
    }
    static func permissions() -> [String: String] {
        ["event": permissionStatus(.event), "reminder": permissionStatus(.reminder), "checkedAt": AgendaWorkflowCodec.now(),
         "bundleID": Bundle.main.bundleIdentifier ?? "unbundled", "bundlePath": Bundle.main.bundlePath,
         "privacyRequest": "not requested by this status query", "AppleWrites": "none"]
    }

    private func require(_ entity: AgendaEntity) throws {
        let status = Self.permissionStatus(entity)
        guard status == "fullAccess" || status == "authorized-legacy" else {
            throw AgendaWorkflowError.invalid("\(entity.rawValue) permission \(status); no automatic privacy request")
        }
    }
    // Invoked only by the separately approved privacy command; never by status/reads/writes.
    func requestReadPrivacyAccess(entities: [AgendaEntity] = [.event, .reminder]) throws -> AgendaPrivacyReport {
        func identity(_ value: AgendaPrivacyReport) -> AgendaPrivacyReport {
            var report = value
            report.bundleID = Bundle.main.bundleIdentifier ?? "unbundled"
            report.bundlePath = Bundle.main.bundlePath
            return report
        }
        do {
            return identity(try AgendaPrivacyRequest.run(entities: entities, status: { Self.permissionStatus($0) },
                request: { self.requestPrivacyOnce($0) }, wait: {
                    // Run the callback-capable run loop, then finish the bounded interval without a busy spin.
                    let end = Date().addingTimeInterval(0.2)
                    _ = RunLoop.current.run(mode: .default, before: end)
                    let remaining = end.timeIntervalSinceNow
                    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                }))
        } catch let failure as AgendaPrivacyFailure {
            throw AgendaPrivacyFailure(report: identity(failure.report))
        }
    }
    private func requestPrivacyOnce(_ entity: AgendaEntity) -> AgendaPrivacyCallback {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var callback = AgendaPrivacyCallback(granted: nil, error: nil)
        let complete: (Bool, Error?) -> Void = { granted, error in
            lock.lock()
            callback.granted = granted
            callback.error = (error as NSError?).map { "\($0.domain) code=\($0.code): \($0.localizedDescription)" }
            lock.unlock(); semaphore.signal()
        }
        if #available(macOS 14.0, *) {
            if entity == .event { store.requestFullAccessToEvents(completion: complete) }
            else { store.requestFullAccessToReminders(completion: complete) }
        } else { store.requestAccess(to: type(entity), completion: complete) }
        let deadline = Date().addingTimeInterval(45)
        while semaphore.wait(timeout: .now()) != .success {
            if Date() >= deadline { return AgendaPrivacyCallback(granted: nil, error: nil, timedOut: true) }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        lock.lock(); defer { lock.unlock() }
        return callback
    }
    private func type(_ entity: AgendaEntity) -> EKEntityType { entity == .event ? .event : .reminder }
    private func calendar(_ reference: AgendaReference, writing: Bool = false) throws -> EKCalendar {
        try require(reference.entity)
        guard let calendar = store.calendar(withIdentifier: reference.calendarID),
              calendar.source.sourceIdentifier == reference.sourceID,
              calendar.allowedEntityTypes.contains(reference.entity == .event ? .event : .reminder),
              !writing || calendar.allowsContentModifications else {
            throw AgendaWorkflowError.invalid("Calendar/source identity missing or calendar is read-only")
        }
        return calendar
    }
    func inventory(_ entities: [AgendaEntity] = [.event, .reminder]) throws -> [AgendaCalendarInfo] {
        var result: [AgendaCalendarInfo] = []
        for entity in entities {
            try require(entity)
            result += store.calendars(for: type(entity)).map {
                AgendaCalendarInfo(entity: entity, sourceID: $0.source.sourceIdentifier, sourceTitle: $0.source.title,
                    calendarID: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications)
            }
        }
        return result
    }

    private func record(_ item: EKCalendarItem, projectedFields: [String] = []) -> AgendaRecord {
        let event = item as? EKEvent, reminder = item as? EKReminder
        var fields = ["title": item.title ?? ""]
        if let event {
            fields["start"] = formatter.string(from: event.startDate)
            fields["end"] = formatter.string(from: event.endDate)
            fields["allDay"] = String(event.isAllDay)
            fields["timeZone"] = event.timeZone?.identifier ?? "" // Empty preserves a floating event.
        }
        if let reminder {
            let due = reminder.dueDateComponents
            fields["dueDate"] = due.flatMap { d in
                guard let year = d.year, let month = d.month, let day = d.day else { return nil }
                return String(format: "%04d-%02d-%02d", year, month, day)
            } ?? ""
            fields["dueTime"] = due.flatMap { d in
                guard let hour = d.hour else { return nil }
                return d.second.map { String(format: "%02d:%02d:%02d", hour, d.minute ?? 0, $0) } ?? String(format: "%02d:%02d", hour, d.minute ?? 0)
            } ?? ""
            fields["dueTimeZone"] = due?.timeZone?.identifier ?? ""
            fields["isCompleted"] = String(reminder.isCompleted)
            fields["priority"] = String(reminder.priority)
        }
        if projectedFields.contains("location") { fields["location"] = item.location }
        if projectedFields.contains("notes") { fields["notes"] = item.notes }
        return AgendaRecord(reference: AgendaReference(entity: event == nil ? .reminder : .event,
            sourceID: item.calendar.source.sourceIdentifier, calendarID: item.calendar.calendarIdentifier,
            appleID: item.calendarItemIdentifier, occurrenceStart: event.map { formatter.string(from: $0.startDate) }),
            appleExternalID: item.calendarItemExternalIdentifier, modifiedAt: item.lastModifiedDate.map { versionFormatter.string(from: $0) },
            recurring: item.hasRecurrenceRules || event?.isDetached == true, hasAttendees: item.hasAttendees, fields: fields, projectedFields: projectedFields.isEmpty ? nil : projectedFields)
    }

    private func resolve(_ reference: AgendaReference) throws -> EKCalendarItem? {
        let calendar = try calendar(reference)
        if reference.entity == .reminder {
            guard let item = store.calendarItem(withIdentifier: reference.appleID) as? EKReminder else { return nil }
            guard item.calendar.calendarIdentifier == reference.calendarID, item.calendar.source.sourceIdentifier == reference.sourceID else {
                throw AgendaWorkflowError.invalid("Apple identifier moved to a different calendar/source")
            }
            return item
        }
        guard let stamp = reference.occurrenceStart else { throw AgendaWorkflowError.invalid("Event occurrence identity required") }
        let start = try AgendaWorkflowCodec.date(stamp)
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1), calendars: [calendar])
        let matches = store.events(matching: predicate).filter {
            $0.calendarItemIdentifier == reference.appleID && formatter.string(from: $0.startDate) == stamp
        }
        guard matches.count <= 1 else { throw AgendaWorkflowError.invalid("Multiple Apple occurrence candidates") }
        return matches.first
    }
    func read(_ reference: AgendaReference) throws -> AgendaRecord? {
        try read(reference, projectedFields: [])
    }
    func read(_ reference: AgendaReference, projectedFields: [String]) throws -> AgendaRecord? {
        guard projectedFields == Array(Set(projectedFields)).sorted(),
              Set(projectedFields).isSubset(of: AgendaWorkflowCodec.textFields) else {
            throw AgendaWorkflowError.invalid("Unsupported text projection")
        }
        if !projectedFields.isEmpty { try AgendaWorkflowCodec.validateTextTarget(reference) }
        try require(reference.entity); store.reset()
        return try resolve(reference).map { record($0, projectedFields: projectedFields) }
    }
    func readTargets(_ request: AgendaTargetReadRequest) throws -> AgendaTargetReadResult {
        try request.validate() // Validate the entire request before accessing Apple.
        let started = AgendaWorkflowCodec.now()
        let rows = try request.targets.map { reference in
            let value = try read(reference, projectedFields: request.fields)
            return AgendaTargetReadRow(target: reference, record: value, state: value == nil ? "missing" : "read")
        }
        return AgendaTargetReadResult(readAt: started, finishedAt: AgendaWorkflowCodec.now(), request: request, rows: rows)
    }

    private func reminders(_ calendars: [EKCalendar]) throws -> [EKReminder] {
        guard !calendars.isEmpty else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [EKReminder]?
        let request = store.fetchReminders(matching: store.predicateForReminders(in: calendars)) { values in result = values; semaphore.signal() }
        let deadline = Date().addingTimeInterval(20)
        while semaphore.wait(timeout: .now()) != .success {
            if Date() >= deadline {
                store.cancelFetchRequest(request)
                throw AgendaWorkflowError.invalid("Reminder read timed out; count unavailable")
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let result else { throw AgendaWorkflowError.invalid("Reminder read returned nil; count unavailable") }
        return result
    }

    func candidates(for operation: AgendaOperation) throws -> [AgendaRecord] {
        store.reset()
        let calendar = try calendar(operation.target)
        let items: [EKCalendarItem]
        if operation.target.entity == .event {
            guard let value = operation.changes["start"] else { throw AgendaWorkflowError.invalid("Create start missing") }
            let start = try AgendaWorkflowCodec.date(value)
            items = store.events(matching: store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(86400), calendars: [calendar]))
        } else { items = try reminders([calendar]) }
        // A title collision is a review candidate, NEVER proof of matching identity.
        return items.filter { $0.title == operation.changes["title"] }.map { record($0) }
    }

    func readAll(_ request: AgendaReadRequest) throws -> AgendaReadResult {
        guard let zone = TimeZone(identifier: request.timeZone), request.eventStart != nil || request.includeReminders,
              (request.eventStart == nil) == (request.eventEnd == nil),
              request.allVisibleSources || !request.sourceIDs.isEmpty || !request.calendarIDs.isEmpty else {
            throw AgendaWorkflowError.invalid("Explicit read scope and valid time zone required")
        }
        if request.allVisibleSources && (!request.sourceIDs.isEmpty || !request.calendarIDs.isEmpty) { throw AgendaWorkflowError.invalid("Ambiguous all-visible and restricted scope") }
        let started = AgendaWorkflowCodec.now()
        let entities: [AgendaEntity] = (request.eventStart == nil ? [] : [.event]) + (request.includeReminders ? [.reminder] : [])
        let info = try inventory(entities).filter {
            request.allVisibleSources || (request.sourceIDs.isEmpty || request.sourceIDs.contains($0.sourceID)) &&
                (request.calendarIDs.isEmpty || request.calendarIDs.contains($0.calendarID))
        }
        guard request.sourceIDs.allSatisfy({ id in info.contains { $0.sourceID == id } }),
              request.calendarIDs.allSatisfy({ id in info.contains { $0.calendarID == id } }) else {
            throw AgendaWorkflowError.invalid("Requested source/list identifier unavailable")
        }
        var records: [AgendaRecord] = [], segments: [[String]] = []
        var seen = Set<String>()
        if let start = request.eventStart, let end = request.eventEnd {
            let windows = try AgendaEventWindows.segments(start: AgendaWorkflowCodec.date(start), end: AgendaWorkflowCodec.date(end), timeZone: zone)
            let calendars = try info.filter { $0.entity == .event }.map { info -> EKCalendar in
                guard let value = store.calendar(withIdentifier: info.calendarID) else { throw AgendaWorkflowError.invalid("Calendar disappeared during read") }
                return value
            }
            for (cursor, next) in windows {
                segments.append([formatter.string(from: cursor), formatter.string(from: next)])
                if !calendars.isEmpty {
                    let events = store.events(matching: store.predicateForEvents(withStart: cursor, end: next, calendars: calendars))
                    for value in events.map({ record($0) }) where seen.insert(try AgendaWorkflowCodec.hash(value.reference)).inserted { records.append(value) }
                }
            }
        }
        if request.includeReminders {
            let calendars = try info.filter { $0.entity == .reminder }.map { info -> EKCalendar in
                guard let value = store.calendar(withIdentifier: info.calendarID) else { throw AgendaWorkflowError.invalid("Reminder list disappeared during read") }
                return value
            }
            records += try reminders(calendars).map { record($0) }
        }
        return AgendaReadResult(readAt: started, finishedAt: AgendaWorkflowCodec.now(), device: ProcessInfo.processInfo.hostName,
            request: request, calendars: info, eventSegments: segments, records: records)
    }

    func apply(_ operation: AgendaOperation) throws -> AgendaReference {
        try AgendaWorkflowCodec.validateOperation(operation) // Same whitelist even if adapter called directly.
        store.reset()
        let projection = AgendaWorkflowCodec.projection(operation)
        let destination = try calendar(operation.target, writing: true)
        let item: EKCalendarItem
        if operation.action == .create {
            item = operation.target.entity == .event ? EKEvent(eventStore: store) : EKReminder(eventStore: store)
            item.calendar = destination
        } else {
            guard let existing = try resolve(operation.target), record(existing, projectedFields: projection) == operation.baseline else {
                throw AgendaWorkflowError.invalid("Target changed at final write precondition")
            }
            item = existing
        }
        guard !item.hasRecurrenceRules, !item.hasAttendees, (item as? EKEvent)?.isDetached != true else {
            throw AgendaWorkflowError.invalid("Recurrence/invitation writes unsupported")
        }
        if let value = operation.changes["title"] { item.title = value }
        if let event = item as? EKEvent {
            AgendaNativeTextPatch.apply(operation, to: event)
            if let start = operation.changes["start"] { event.startDate = try AgendaWorkflowCodec.date(start) }
            if let end = operation.changes["end"] { event.endDate = try AgendaWorkflowCodec.date(end) }
            if let allDay = operation.changes["allDay"] { event.isAllDay = allDay == "true" }
            if let zone = operation.changes["timeZone"] { event.timeZone = zone.isEmpty ? nil : TimeZone(identifier: zone) }
            try store.save(event, span: .thisEvent, commit: true)
        } else if let reminder = item as? EKReminder {
            let fields = AgendaWorkflowCodec.expectedFields(operation)
            if operation.changes.keys.contains(where: { $0.hasPrefix("due") }) {
                if let originalCalendar = reminder.dueDateComponents?.calendar, originalCalendar.identifier != .gregorian {
                    throw AgendaWorkflowError.invalid("Non-Gregorian reminder date requires manual handling")
                }
                reminder.dueDateComponents = try AgendaDateComponents.parse(date: fields["dueDate"] ?? "", time: fields["dueTime"] ?? "", zone: fields["dueTimeZone"] ?? "")
            }
            if let priority = operation.changes["priority"] { reminder.priority = Int(priority)! }
            try store.save(reminder, commit: true)
        }
        return record(item).reference
    }
}
