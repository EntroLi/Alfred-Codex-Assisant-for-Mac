import Foundation

struct AgendaReminderCapabilities: Codable {
    var checkedAt: String
    var permission: String
    var bundleID: String
    var bundlePath: String
    var supportedReadFields = ["title", "dueDate", "dueTime", "dueTimeZone", "priority", "isCompleted", "notes (opt-in)", "completionDate (opt-in)"]
    var supportedWriteFields = ["title", "dueDate", "dueTime", "dueTimeZone", "priority", "notes (append/replace/clear)", "isCompleted (standalone human-reviewed only)"]
    var singleDelete = "Conditional: exact ID, versioned baseline, fresh human native-UI standalone review, no-recovery acknowledgement and specific approval"
    var nativeParentChildRead = false
    var nativeParentChildCreate = false
    var nativeParentChildChange = false
    var hierarchyStatus = "UNKNOWN: no public EventKit parent/children API; flat records cannot identify parent/child status"
    var childCount: Int? = nil
    var permanentDelete = "Unsupported: no API for deleting Recently Deleted content or automatic purge"
    var normalRecovery = "Apple Reminders UI may recover Recently Deleted within 30 days on supported accounts/OS; this adapter's removal routing is NOT VERIFIED"
    var programmaticRestore = false
    var preservesOriginalIDOnRestore = "UNKNOWN; no guarantee; exported JSON is evidence, not native restoration"
    var limitations = ["Completion/reopen/delete of an existing parent or child is blocked; only human-reviewed standalone items",
                       "Hierarchy-only phone changes are invisible to EventKit; native UI review cannot provide atomic cross-device protection",
                       "Recurring and invited item writes unsupported; no alarms/URL/location/relations setters",
                       "CompletionDate is native read-only output; complete sets current native time and reopen clears it",
                       "Denied/nil/timeout does not mean zero reminders; capabilities reads no personal entries"]
    var AppleReads = "none"
    var AppleWrites = "none"
    static func current(permission: String) -> AgendaReminderCapabilities {
        AgendaReminderCapabilities(checkedAt: AgendaWorkflowCodec.now(), permission: permission,
            bundleID: Bundle.main.bundleIdentifier ?? "unbundled", bundlePath: Bundle.main.bundlePath)
    }
}

// The adapter and simulation use exactly the same public setter boundary.
protocol AgendaNativeReminderItem: AgendaNativeTextItem {
    var isCompleted: Bool { get set }
    var priority: Int { get set }
    var dueDateComponents: DateComponents? { get set }
}
enum AgendaNativeReminderPatch {
    static func apply(_ operation: AgendaOperation, to item: AgendaNativeReminderItem) throws {
        let fields = AgendaWorkflowCodec.expectedFields(operation)
        let changesDue = operation.changes.keys.contains { $0.hasPrefix("due") }
        var due: DateComponents?
        if changesDue {
            if let calendar = item.dueDateComponents?.calendar, calendar.identifier != .gregorian {
                throw AgendaWorkflowError.invalid("Non-Gregorian reminder date requires manual handling")
            }
            due = try AgendaDateComponents.parse(date: fields["dueDate"] ?? "", time: fields["dueTime"] ?? "", zone: fields["dueTimeZone"] ?? "")
        }
        AgendaNativeTextPatch.apply(operation, to: item)
        if changesDue { item.dueDateComponents = due }
        if let priority = operation.changes["priority"] { item.priority = Int(priority)! }
        // No completionDate assignment: the public isCompleted setter supplies correct native semantics.
        if let completed = operation.changes["isCompleted"] { item.isCompleted = completed == "true" }
    }
}
