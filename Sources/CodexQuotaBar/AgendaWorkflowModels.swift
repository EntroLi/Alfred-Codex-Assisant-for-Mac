import Foundation
import CryptoKit

enum AgendaWorkflowError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let value) = self { return value }; return "unknown" }
}

enum AgendaEntity: String, Codable { case event, reminder }
enum AgendaOperationKind: String, Codable { case create, update, delete }
enum AgendaNotesMode: String, Codable { case replace, append }

struct AgendaReference: Codable, Equatable {
    var entity: AgendaEntity
    var sourceID: String
    var calendarID: String
    var appleID: String
    // Required for event occurrence identity; never use the title as identity.
    var occurrenceStart: String?
}

struct AgendaRecord: Codable, Equatable {
    var reference: AgendaReference
    var appleExternalID: String?
    var modifiedAt: String?
    var recurring: Bool
    var hasAttendees: Bool
    // Text fields are opt-in. Projected-but-absent means native nil; an empty string remains distinct.
    var fields: [String: String]
    // Optional to preserve byte-for-byte encoding of schema-1 legacy batches and receipts.
    var projectedFields: [String]? = nil
}

struct AgendaSourceVersion: Codable, Equatable {
    var pageID: String
    var version: String
    var readAt: String
    var contentSHA256: String
}

struct AgendaOperation: Codable, Equatable {
    var id: String
    var externalID: String
    var action: AgendaOperationKind
    var target: AgendaReference
    var baseline: AgendaRecord?
    // Patch fields only. Empty dueDate/dueTime/dueTimeZone mean clear.
    var changes: [String: String]
    var recurrenceScope: String
    var relationshipScope: String
    // Clear a native nullable text field; never use an empty string to imply nil.
    var clearFields: [String]? = nil
    var notesMode: AgendaNotesMode? = nil
    // Explicitly approved single-event deletion; no guarantee of restoring original identity.
    var allowIrrecoverableDelete: Bool? = nil
}

struct AgendaBatch: Codable, Equatable {
    var schemaVersion = 1
    var batchID: String
    var source: AgendaSourceVersion
    var timeZone: String
    var operations: [AgendaOperation]
}

struct AgendaPreview: Codable {
    var batch: AgendaBatch
    var previewSHA256: String
    var previewedAt: String
    var rows: [AgendaPreviewRow]
    var limitations = ["EventKit has no atomic compare-and-swap across devices",
                      "Series edits and native parent/child edits are unsupported",
                      "Only approved text patches are written; participants, alarms and unrelated fields are preserved"]
}

struct AgendaPreviewRow: Codable {
    var operationID: String
    var before: [String: String]?
    var after: [String: String]?
    var state: String
    var reason: String?
    var textDifferences: [AgendaTextDifference]? = nil
}

struct AgendaTextDifference: Codable {
    var field: String
    var mode: String
    var before: String?
    var after: String?
    // Always emit null for native nil, so review does not confuse nil with unread/empty.
    enum CodingKeys: String, CodingKey { case field, mode, before, after }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field); try c.encode(mode, forKey: .mode)
        if let before { try c.encode(before, forKey: .before) } else { try c.encodeNil(forKey: .before) }
        if let after { try c.encode(after, forKey: .after) } else { try c.encodeNil(forKey: .after) }
    }
}

struct AgendaTargetReadRequest: Codable {
    var targets: [AgendaReference]
    var fields: [String]
    func validate() throws {
        guard !targets.isEmpty, targets.count <= 100, !fields.isEmpty,
              fields == Array(Set(fields)).sorted(), Set(fields).isSubset(of: AgendaWorkflowCodec.textFields),
              Set(try targets.map { try AgendaWorkflowCodec.hash($0) }).count == targets.count else {
            throw AgendaWorkflowError.invalid("Exact unique targets and sorted explicit location/notes projection required (max 100)")
        }
        for target in targets { try AgendaWorkflowCodec.validateTextTarget(target) }
    }
}

struct AgendaTargetReadRow: Codable {
    var target: AgendaReference
    var record: AgendaRecord?
    var state: String
}

struct AgendaTargetReadResult: Codable {
    var readAt: String
    var finishedAt: String
    var request: AgendaTargetReadRequest
    var rows: [AgendaTargetReadRow]
    var writeAuthorization = "none"
}

struct AgendaApproval: Codable, Equatable {
    var batchID: String
    var previewSHA256: String
    var operationIDs: [String]
    var approvedBy: String
    var approvedAt: String
    var statement: String
}

struct AgendaOperationReceipt: Codable {
    var operationID: String
    // prepared/pending/unknown are never reported as success.
    var status: String
    var appleReference: AgendaReference?
    var readback: AgendaRecord?
    var reason: String?
    var recoveryCandidates: [AgendaRecord]? = nil
}

struct AgendaReceipt: Codable {
    var batch: AgendaBatch
    var previewSHA256: String
    var approval: AgendaApproval
    var device: String
    var startedAt: String
    var finishedAt: String?
    var path = "Alfred manual EventKit"
    var readScope = "Exact targets and create deduplication candidates in approved calendars"
    var results: [AgendaOperationReceipt]
    var mappings: [String: AgendaReference] = [:]
    var sourceVerifiedAt: String?
    var unchangedScope = "Fields outside changes; no Space writes; no automated completion or rescheduling"
}

protocol AgendaWorkflowStore {
    func read(_ reference: AgendaReference) throws -> AgendaRecord?
    func read(_ reference: AgendaReference, projectedFields: [String]) throws -> AgendaRecord?
    func candidates(for operation: AgendaOperation) throws -> [AgendaRecord]
    func apply(_ operation: AgendaOperation) throws -> AgendaReference
}

extension AgendaWorkflowStore {
    func read(_ reference: AgendaReference, projectedFields: [String]) throws -> AgendaRecord? {
        guard projectedFields.isEmpty else { throw AgendaWorkflowError.invalid("Store does not support explicit text projection") }
        return try read(reference)
    }
}

// The adapter and simulation use this same setter boundary; no other native properties assigned here.
protocol AgendaNativeTextItem: AnyObject {
    var location: String? { get set }
    var notes: String? { get set }
}
enum AgendaNativeTextPatch {
    static func apply(_ operation: AgendaOperation, to item: AgendaNativeTextItem) {
        let expected = AgendaWorkflowCodec.expectedFields(operation)
        let touched = Set(operation.changes.keys).union(operation.clearFields ?? [])
        if touched.contains("location") { item.location = expected["location"] }
        if touched.contains("notes") { item.notes = expected["notes"] }
    }
}

enum AgendaWorkflowCodec {
    static let textFields: Set<String> = ["location", "notes"]
    static func validateTextTarget(_ target: AgendaReference) throws {
        guard target.entity == .event, !target.sourceID.isEmpty, !target.calendarID.isEmpty,
              !target.appleID.isEmpty, let start = target.occurrenceStart else {
            throw AgendaWorkflowError.invalid("Text reads require an exact event source/calendar/Apple ID/occurrence; no reminder text reads")
        }
        _ = try date(start)
    }
    static func projection(_ operation: AgendaOperation) -> [String] {
        Set(operation.baseline?.projectedFields ?? []).union(Set(operation.changes.keys).intersection(textFields))
            .union(operation.clearFields ?? []).sorted()
    }
    static func textDifferences(_ operation: AgendaOperation) -> [AgendaTextDifference]? {
        let touched = Set(operation.changes.keys).intersection(textFields).union(operation.clearFields ?? []).sorted()
        guard !touched.isEmpty else { return nil }
        let expected = expectedFields(operation)
        return touched.map { AgendaTextDifference(field: $0,
            mode: (operation.clearFields ?? []).contains($0) ? "clear" : ($0 == "notes" ? operation.notesMode?.rawValue ?? "replace" : "replace"),
            before: operation.baseline?.fields[$0], after: expected[$0]) }
    }
    static func confirms(_ current: AgendaRecord?, operation: AgendaOperation, reference: AgendaReference) -> Bool {
        guard let current else { return false }
        let projection = projection(operation)
        return current.reference == reference && current.fields == expectedFields(operation) &&
            (current.projectedFields ?? []) == projection && !current.recurring && !current.hasAttendees
    }
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func hash<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func date(_ value: String) throws -> Date {
        guard let result = ISO8601DateFormatter().date(from: value) else { throw AgendaWorkflowError.invalid("Invalid ISO-8601 date: " + value) }
        return result
    }
    static func expectedFields(_ operation: AgendaOperation) -> [String: String] {
        var fields = operation.baseline?.fields ?? (operation.target.entity == .reminder ?
            ["dueDate": "", "dueTime": "", "dueTimeZone": "", "priority": "0", "isCompleted": "false"] : [:])
        fields.merge(operation.changes) { _, new in new }
        if operation.notesMode == .append, let addition = operation.changes["notes"] {
            let previous = operation.baseline?.fields["notes"] ?? ""
            fields["notes"] = previous.isEmpty ? addition : previous + "\n\n" + addition
        }
        for field in operation.clearFields ?? [] { fields.removeValue(forKey: field) }
        return fields
    }
    static func validate(_ batch: AgendaBatch) throws {
        guard batch.schemaVersion == 1, !batch.batchID.isEmpty, !batch.operations.isEmpty,
              !batch.source.pageID.isEmpty, !batch.source.version.isEmpty,
              batch.source.contentSHA256.count == 64,
              batch.source.contentSHA256.allSatisfy({ "0123456789abcdef".contains($0) }), TimeZone(identifier: batch.timeZone) != nil else {
            throw AgendaWorkflowError.invalid("Missing batch/source/version/time zone; source page pending is not executable")
        }
        _ = try date(batch.source.readAt)
        guard Set(batch.operations.map(\.id)).count == batch.operations.count,
              Set(batch.operations.map(\.externalID)).count == batch.operations.count else {
            throw AgendaWorkflowError.invalid("Duplicate operation or external stable identifier")
        }
        let existingTargets = try batch.operations.filter { $0.action != .create }.map { try hash($0.target) }
        guard Set(existingTargets).count == existingTargets.count else {
            throw AgendaWorkflowError.invalid("Multiple operations on the same target require one combined approved patch")
        }
        for op in batch.operations { try validateOperation(op) }
    }

    static func validateOperation(_ op: AgendaOperation) throws {
        guard !op.id.isEmpty, !op.externalID.isEmpty, !op.target.sourceID.isEmpty,
              !op.target.calendarID.isEmpty, op.relationshipScope == "none",
              op.recurrenceScope == "this" else {
            throw AgendaWorkflowError.invalid("Explicit IDs required; series and native parent/child operations unsupported")
        }
        let allowed: Set<String> = op.target.entity == .event ?
            ["title", "start", "end", "allDay", "timeZone", "location", "notes"] : ["title", "dueDate", "dueTime", "dueTimeZone", "priority"]
        guard Set(op.changes.keys).isSubset(of: allowed) else {
            throw AgendaWorkflowError.invalid("Unsupported field: only title/time/location/notes patches; category is identity, not writable")
        }
        if op.action == .delete {
            guard op.target.entity == .event, op.allowIrrecoverableDelete == true,
                  op.changes.isEmpty, op.clearFields == nil, op.notesMode == nil else {
                throw AgendaWorkflowError.invalid("Single-event deletion requires explicit no-recovery acknowledgement and no patches")
            }
        } else if op.allowIrrecoverableDelete != nil {
            throw AgendaWorkflowError.invalid("Delete acknowledgement on non-delete operation")
        }
        let clear = op.clearFields ?? []
        guard clear == Array(Set(clear)).sorted(), Set(clear).isSubset(of: textFields),
              Set(clear).isDisjoint(with: Set(op.changes.keys)), op.target.entity == .event || clear.isEmpty && op.notesMode == nil else {
            throw AgendaWorkflowError.invalid("Only event location/notes may be explicitly cleared; no overlapping patches")
        }
        if let projection = op.baseline?.projectedFields {
            guard projection == Array(Set(projection)).sorted(), Set(projection).isSubset(of: textFields),
                  op.target.entity == .event else { throw AgendaWorkflowError.invalid("Invalid baseline text projection") }
        }
        let projected = Set(op.baseline?.projectedFields ?? [])
        let carriedText = Set(op.baseline?.fields.keys.map { $0 } ?? []).intersection(textFields)
        guard carriedText.isSubset(of: projected) else { throw AgendaWorkflowError.invalid("Text baseline requires an explicit projection") }
        if op.action != .create {
            let touched = Set(op.changes.keys).intersection(textFields).union(clear)
            guard touched.isSubset(of: projected) else { throw AgendaWorkflowError.invalid("Read the exact target text fields before preview, including native nil") }
        }
        let touchesNotes = op.changes["notes"] != nil || clear.contains("notes")
        guard touchesNotes == (op.notesMode != nil) else { throw AgendaWorkflowError.invalid("Every notes patch requires explicit append/replace mode; no unused mode") }
        if op.notesMode == .append {
            guard op.action == .update, let addition = op.changes["notes"], !addition.isEmpty, !clear.contains("notes") else {
                throw AgendaWorkflowError.invalid("Append requires an existing exact notes baseline and nonempty addition")
            }
        }
        if op.action == .create {
            guard op.baseline == nil, op.target.appleID.isEmpty, op.target.occurrenceStart == nil else {
                throw AgendaWorkflowError.invalid("Creation must not carry an existing Apple identity")
            }
        } else {
            guard let baseline = op.baseline, baseline.reference == op.target,
                  !op.target.appleID.isEmpty, baseline.modifiedAt != nil else {
                throw AgendaWorkflowError.invalid("Modification requires exact identity and a versioned baseline")
            }
            if baseline.hasAttendees || baseline.recurring || op.target.entity == .reminder && op.action == .delete {
                throw AgendaWorkflowError.invalid("Invitations, recurring item writes and reminder deletion require manual handling in v1")
            }
            if op.action == .update && op.changes.isEmpty && clear.isEmpty { throw AgendaWorkflowError.invalid("Empty update") }
        }
        let fields = expectedFields(op)
        guard let title = fields["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgendaWorkflowError.invalid("Title required")
        }
        if op.target.entity == .event {
            if op.action != .create { try validateTextTarget(op.target) }
            guard let start = fields["start"], let end = fields["end"], let allDay = fields["allDay"],
                  ["true", "false"].contains(allDay), let zone = fields["timeZone"],
                  (zone.isEmpty || TimeZone(identifier: zone) != nil), try date(start) < date(end) else {
                throw AgendaWorkflowError.invalid("Valid event dates/allDay/timeZone required")
            }
        } else {
            guard let priority = Int(fields["priority"] ?? "0"), (0...9).contains(priority) else {
                throw AgendaWorkflowError.invalid("Reminder priority must be 0...9")
            }
            _ = try AgendaDateComponents.parse(date: fields["dueDate"] ?? "", time: fields["dueTime"] ?? "", zone: fields["dueTimeZone"] ?? "")
        }
    }
}

enum AgendaDateComponents {
    static func parse(date: String, time: String, zone: String) throws -> DateComponents? {
        if date.isEmpty {
            guard time.isEmpty && zone.isEmpty else { throw AgendaWorkflowError.invalid("Time/zone without date") }
            return nil
        }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, date.count == 10 else { throw AgendaWorkflowError.invalid("Invalid date-only value") }
        var components = DateComponents(); var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        components.calendar = calendar; components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        guard let value = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: value).year == parts[0],
              calendar.component(.month, from: value) == parts[1], calendar.component(.day, from: value) == parts[2] else {
            throw AgendaWorkflowError.invalid("Invalid calendar date")
        }
        if !time.isEmpty {
            let clock = time.split(separator: ":").compactMap { Int($0) }
            guard (clock.count == 2 && time.count == 5 || clock.count == 3 && time.count == 8),
                  (0...23).contains(clock[0]), (0...59).contains(clock[1]), clock.count < 3 || (0...59).contains(clock[2]) else {
                throw AgendaWorkflowError.invalid("Invalid due time")
            }
            components.hour = clock[0]; components.minute = clock[1]
            if clock.count == 3 { components.second = clock[2] }
        }
        if !zone.isEmpty {
            guard let zone = TimeZone(identifier: zone) else { throw AgendaWorkflowError.invalid("Invalid due time zone") }
            components.timeZone = zone
        }
        // A date-only reminder never receives an hour, minute, second or alarm.
        return components
    }
}

enum AgendaEventWindows {
    static func segments(start: Date, end: Date, timeZone: TimeZone) throws -> [(Date, Date)] {
        guard start < end else { throw AgendaWorkflowError.invalid("Read window must have positive length") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var cursor = start, result: [(Date, Date)] = []
        while cursor < end {
            guard result.count < 100, let nextYear = calendar.date(byAdding: .year, value: 1, to: cursor) else {
                throw AgendaWorkflowError.invalid("Window too large; use explicit smaller windows")
            }
            let next = min(nextYear, end); result.append((cursor, next)); cursor = next
        }
        return result
    }
}
