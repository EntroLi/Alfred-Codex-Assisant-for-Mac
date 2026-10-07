import Foundation
import Testing
@testable import CodexQuotaBar

private final class NativeReminderSimulation: AgendaNativeReminderItem {
    var location: String? = "unchanged location"
    var notes: String? = "original notes"
    var completionDate: String?
    var isCompleted = false { didSet { completionDate = isCompleted ? "2026-10-07T12:00:00Z" : nil } }
    var priority = 5
    var dueDateComponents: DateComponents?
    // These have no setter in the shared adapter protocol.
    let url = "synthetic://unchanged", alarms = ["original alarm"], relationships = "unknown"
}
private final class ReminderWorkflowSimulation: AgendaWorkflowStore {
    var records: [String: AgendaRecord] = [:]
    var writes = 0
    var loseResponse = false
    var failReadAfterWrite = false
    var alterReadback = false
    var alterReadbackAt: Int? = nil
    func read(_ reference: AgendaReference) throws -> AgendaRecord? { try read(reference, projectedFields: []) }
    func read(_ reference: AgendaReference, projectedFields: [String]) throws -> AgendaRecord? {
        if failReadAfterWrite && writes > 0 { throw AgendaWorkflowError.invalid("Synthetic read failed, not empty") }
        return records[reference.appleID]
    }
    func candidates(for operation: AgendaOperation) throws -> [AgendaRecord] { records.values.filter { $0.fields["title"] == operation.changes["title"] } }
    func apply(_ operation: AgendaOperation) throws -> AgendaReference {
        writes += 1
        let reference = operation.target
        if operation.action == .delete { records.removeValue(forKey: reference.appleID) }
        else {
            var item = operation.baseline!
            item.fields = AgendaWorkflowCodec.expectedFields(operation)
            if operation.changes["isCompleted"] == "true" { item.fields["completionDate"] = "2026-10-07T12:00:00Z" }
            if alterReadback || alterReadbackAt == writes { item.fields["title"] = "phone edit" }
            item.modifiedAt = "new-synthetic-version"
            records[reference.appleID] = item
        }
        if loseResponse { throw AgendaWorkflowError.invalid("Synthetic response lost after native boundary") }
        return reference
    }
}
struct AgendaReminderWorkflowTests {
    private func record(_ id: String = "target", completed: Bool = false) -> AgendaRecord {
        AgendaRecord(reference: AgendaReference(entity: .reminder, sourceID: "synthetic-source", calendarID: "synthetic-list", appleID: id, occurrenceStart: nil),
            modifiedAt: "original-synthetic-version", recurring: false, hasAttendees: false,
            fields: ["title": "same title", "notes": "original notes", "dueDate": "2026-10-09", "dueTime": "", "dueTimeZone": "",
                     "priority": "5", "isCompleted": String(completed)], projectedFields: ["completionDate", "notes"])
    }
    private func op(_ item: AgendaRecord, changes: [String:String]) -> AgendaOperation {
        AgendaOperation(id: "op-" + item.reference.appleID, externalID: "synthetic:" + item.reference.appleID, action: .update,
            target: item.reference, baseline: item, changes: changes, recurrenceScope: "this", relationshipScope: "none")
    }
    private func reviewed(_ value: AgendaOperation) throws -> AgendaOperation {
        var value = value
        value.reminderStandaloneReview = AgendaReminderStandaloneReview(baselineSHA256: try AgendaWorkflowCodec.hash(value.baseline!),
            reviewedAt: AgendaWorkflowCodec.now(), reviewedBy: "human-user", statement: "Native UI verified standalone; no parent or children")
        return value
    }
    private func source() -> AgendaSourceVersion { AgendaSourceVersion(pageID: "synthetic-page", version: "1", readAt: AgendaWorkflowCodec.now(), contentSHA256: String(repeating: "a", count: 64)) }
    private func batch(_ ops: [AgendaOperation]) -> AgendaBatch { AgendaBatch(batchID: UUID().uuidString, source: source(), timeZone: "Asia/Shanghai", operations: ops) }
    private func approval(_ preview: AgendaPreview, ids: [String]? = nil) -> AgendaApproval {
        AgendaApproval(batchID: preview.batch.batchID, previewSHA256: preview.previewSHA256, operationIDs: ids ?? preview.batch.operations.map(\.id),
            approvedBy: "human-user", approvedAt: AgendaWorkflowCodec.now(), statement: "Approve exactly these operations and fields")
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reminder-tests-" + UUID().uuidString) }

    @Test func notesAppendReplaceClearPreserveOtherNativeFields() throws {
        let native = NativeReminderSimulation(); native.dueDateComponents = try AgendaDateComponents.parse(date: "2026-10-09", time: "", zone: "")
        let originalDue = native.dueDateComponents; var value = op(record(), changes: ["notes":"addition"]); value.notesMode = .append
        try AgendaWorkflowCodec.validateOperation(value); try AgendaNativeReminderPatch.apply(value, to: native)
        #expect(native.notes == "original notes\n\naddition" && native.location == "unchanged location")
        #expect(native.dueDateComponents == originalDue && native.alarms == ["original alarm"] && native.url == "synthetic://unchanged" && !native.isCompleted)
        value.notesMode = .replace; value.changes["notes"] = "replacement"; try AgendaNativeReminderPatch.apply(value, to: native)
        #expect(native.notes == "replacement")
        value.changes = [:]; value.clearFields = ["notes"]; try AgendaWorkflowCodec.validateOperation(value); try AgendaNativeReminderPatch.apply(value, to: native)
        #expect(native.notes == nil && native.priority == 5)
    }
    @Test func unreadNotesAndMissingModeAreRejectedAndNilDiffIsExplicit() throws {
        var value = op(record(), changes: ["notes":"addition"]); value.notesMode = .append; value.baseline?.projectedFields = ["completionDate"]
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
        value = op(record(), changes: ["notes":"addition"])
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
        value.notesMode = .replace; value.baseline?.fields.removeValue(forKey: "notes")
        try AgendaWorkflowCodec.validateOperation(value)
        let object = try JSONSerialization.jsonObject(with: AgendaWorkflowCodec.data(AgendaWorkflowCodec.textDifferences(value)!)) as! [[String:Any]]
        #expect(object[0]["before"] is NSNull)
    }
    @Test func exactReminderProjectionRejectsParentAndWrongEntityFields() throws {
        try AgendaTargetReadRequest(targets:[record().reference],fields:["completionDate","notes"]).validate()
        for field in ["location","parentID","children","structuredLocation"] {
            #expect(throws: (any Error).self) { try AgendaTargetReadRequest(targets:[record().reference],fields:[field]).validate() }
        }
        var r = record().reference; r.occurrenceStart = "2026-10-09T00:00:00Z"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateTextTarget(r) }
    }
    @Test func completionAndReopenUseNativeTimestampAndKeepDateOnly() throws {
        let native = NativeReminderSimulation(); native.dueDateComponents = try AgendaDateComponents.parse(date: "2026-10-09", time: "", zone: "")
        var value = try reviewed(op(record(),changes:["isCompleted":"true"]))
        try AgendaWorkflowCodec.validateOperation(value); try AgendaNativeReminderPatch.apply(value,to:native)
        #expect(native.isCompleted && native.completionDate != nil && native.notes == "original notes")
        #expect(native.dueDateComponents?.hour == nil && native.dueDateComponents?.timeZone == nil && native.alarms == ["original alarm"])
        var current = record(completed:true); current.fields["completionDate"] = native.completionDate
        #expect(AgendaWorkflowCodec.confirms(current,operation:value,reference:current.reference))
        value = try reviewed(op(current,changes:["isCompleted":"false"])); try AgendaNativeReminderPatch.apply(value,to:native)
        #expect(!native.isCompleted && native.completionDate == nil)
        current.fields["isCompleted"] = "false"
        #expect(!AgendaWorkflowCodec.confirms(current,operation:value,reference:current.reference))
        current.fields.removeValue(forKey:"completionDate")
        #expect(AgendaWorkflowCodec.confirms(current,operation:value,reference:current.reference))
    }
    @Test func completedWithoutNativeDateIsLegitimateButUserTimestampRejected() throws {
        let value = try reviewed(op(record(),changes:["isCompleted":"true"])); let current = record(completed:true)
        #expect(AgendaWorkflowCodec.confirms(current,operation:value,reference:current.reference))
        var bad = value; bad.changes["completionDate"] = "2026-10-07T12:00:00Z"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(bad) }
    }
    @Test func sensitiveActionsRequireFreshExactHumanStandaloneReview() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at:folder) }
        let store = ReminderWorkflowSimulation(); store.records["target"] = record()
        let engine = AgendaWorkflowEngine(store:store,ledger:AgendaWorkflowLedger(root:folder)); var value = op(record(),changes:["isCompleted":"true"])
        #expect(throws: (any Error).self) { try engine.preview(batch([value])) }
        value = try reviewed(value); value.reminderStandaloneReview?.baselineSHA256 = String(repeating:"b",count:64)
        #expect(throws: (any Error).self) { try engine.preview(batch([value])) }
        value = try reviewed(value); value.reminderStandaloneReview?.reviewedAt = "2026-01-01T00:00:00Z"
        #expect(try engine.preview(batch([value])).rows[0].state == "blocked")
        #expect(store.writes == 0)
    }
    @Test func duplicateCompleteAndReopenNeverRepeatNativeWrites() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at:folder) }
        let store = ReminderWorkflowSimulation(); store.records["target"] = record(); let engine = AgendaWorkflowEngine(store:store,ledger:AgendaWorkflowLedger(root:folder))
        let value = try reviewed(op(record(),changes:["isCompleted":"true"])), preview = try engine.preview(batch([value]))
        let first = try engine.execute(preview,approval:approval(preview),sourceNow:{source()})
        #expect(first.results[0].status == "success" && first.results[0].readback?.fields["completionDate"] != nil)
        _ = try engine.execute(preview,approval:nil,sourceNow:{source()}); #expect(store.writes == 1)
        let reopen = try reviewed(op(store.records["target"]!,changes:["isCompleted":"false"])), secondPreview = try engine.preview(batch([reopen]))
        let second = try engine.execute(secondPreview,approval:approval(secondPreview),sourceNow:{source()})
        #expect(second.results[0].status == "success" && second.results[0].readback?.fields["completionDate"] == nil)
        _ = try engine.execute(secondPreview,approval:nil,sourceNow:{source()}); #expect(store.writes == 2)
    }
    @Test func sameTitleDifferentIDsStaySeparateAndApprovedSubsetOnlyRuns() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at:folder) }; let store = ReminderWorkflowSimulation()
        store.records = ["target":record(),"other":record("other")]; let engine = AgendaWorkflowEngine(store:store,ledger:AgendaWorkflowLedger(root:folder))
        var a = op(record(),changes:["notes":"one"]); a.notesMode = .append
        var b = op(record("other"),changes:["notes":"two"]); b.notesMode = .append
        let preview = try engine.preview(batch([a,b])); let result = try engine.execute(preview,approval:approval(preview,ids:[a.id]),sourceNow:{source()})
        #expect(result.results.map(\.status) == ["success","skipped"] && store.writes == 1)
        #expect(store.records["other"]?.fields["notes"] == "original notes")
    }
    @Test func phoneChangesBlockBeforeWritesIncludingNilToTextChange() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at:folder) }; let store = ReminderWorkflowSimulation(); store.records["target"] = record()
        let engine = AgendaWorkflowEngine(store:store,ledger:AgendaWorkflowLedger(root:folder)); var value = op(record(),changes:["notes":"one"]); value.notesMode = .append
        let preview = try engine.preview(batch([value])); store.records["target"]?.fields["notes"] = "phone changed notes"
        #expect(throws: (any Error).self) { try engine.execute(preview,approval:approval(preview),sourceNow:{source()}) }
        #expect(store.writes == 0)
    }
    @Test func lostDeleteResponseReconcilesWithoutReDeleteAndNoRecoveryPromise() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at:folder) }; let store = ReminderWorkflowSimulation()
        store.records = ["target":record(),"other":record("other")]; store.loseResponse = true
        let engine = AgendaWorkflowEngine(store:store,ledger:AgendaWorkflowLedger(root:folder)); var value = op(record(),changes:[:]); value.action = .delete; value.allowIrrecoverableDelete = true; value = try reviewed(value)
        let preview = try engine.preview(batch([value])); #expect(preview.rows[0].reminderWarnings?.contains(where:{$0.contains("JSON is evidence only")}) == true)
        let first = try engine.execute(preview,approval:approval(preview),sourceNow:{source()}); #expect(first.results[0].status == "unknown" && store.writes == 1)
        let next = try engine.readReceipt(preview.batch.batchID); #expect(next.results[0].status == "success" && store.records["other"] != nil)
        _ = try engine.execute(preview,approval:nil,sourceNow:{source()}); #expect(store.writes == 1)
    }
    @Test func deleteWithoutNoRecoveryAcknowledgementAndRecurringDeleteRejected() throws {
        var value = op(record(),changes:[:]); value.action = .delete; value = try reviewed(value)
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
        value.allowIrrecoverableDelete = true; try AgendaWorkflowCodec.validateOperation(value)
        value.baseline?.recurring = true; value = try reviewed(value)
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
        value = try reviewed(op(record(),changes:["isCompleted":"false"])); value.baseline?.hasAttendees = true; value = try reviewed(value)
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
    }
    @Test func readFailureAfterWriteRemainsUnknownNotEmptySuccess() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at:folder) }; let store = ReminderWorkflowSimulation(); store.records["target"] = record(); store.failReadAfterWrite = true
        let engine = AgendaWorkflowEngine(store:store,ledger:AgendaWorkflowLedger(root:folder)); var value = op(record(),changes:["notes":"one"]); value.notesMode = .append
        let preview = try engine.preview(batch([value])); let first = try engine.execute(preview,approval:approval(preview),sourceNow:{source()})
        #expect(first.results[0].status == "unknown" && store.writes == 1)
        let next = try engine.readReceipt(preview.batch.batchID); #expect(next.results[0].status == "unknown" && store.writes == 1)
    }
    @Test func partialSuccessAndUnknownHaltRemainingActions() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at:folder) }; let store = ReminderWorkflowSimulation()
        store.records = ["target":record(),"other":record("other"),"third":record("third")]; store.alterReadbackAt = 2
        let engine = AgendaWorkflowEngine(store:store,ledger:AgendaWorkflowLedger(root:folder)); var a = op(record(),changes:["notes":"one"]); a.notesMode = .append
        var b = op(record("other"),changes:["notes":"two"]); b.notesMode = .append
        var c = op(record("third"),changes:["notes":"three"]); c.notesMode = .append
        let preview = try engine.preview(batch([a,b,c])); let result = try engine.execute(preview,approval:approval(preview),sourceNow:{source()})
        #expect(result.results.map(\.status) == ["success","unknown","skipped"] && store.writes == 2)
    }
    @Test func dateOnlyDuePatchAddsNoMidnightOrAlarmAndRejectsInvalidDay() throws {
        let native = NativeReminderSimulation(); let value = op(record(),changes:["dueDate":"2026-10-11"])
        try AgendaWorkflowCodec.validateOperation(value); try AgendaNativeReminderPatch.apply(value,to:native)
        #expect(native.dueDateComponents?.hour == nil && native.dueDateComponents?.timeZone == nil && native.alarms == ["original alarm"])
        var bad = value; bad.changes["dueDate"] = "2026-02-30"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(bad) }
    }
    @Test func capabilityReportsUnknownHierarchyAndCannotFabricateNativeParentage() throws {
        let c = AgendaReminderCapabilities.current(permission:"notDetermined")
        #expect(!c.nativeParentChildRead && !c.nativeParentChildCreate && !c.nativeParentChildChange && c.childCount == nil && !c.programmaticRestore)
        for key in ["parentID","children","subtasks","completionDate","location"] {
            let value = op(record(),changes:[key:"fake"])
            #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
        }
        var value = op(record(),changes:["title":"fake indent"]); value.relationshipScope = "children"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
    }
    @Test func ordinaryCreateSupportsNotesWithoutFakeRelationsOrCompletion() throws {
        let reference = AgendaReference(entity:.reminder,sourceID:"synthetic-source",calendarID:"synthetic-list",appleID:"",occurrenceStart:nil)
        var value = AgendaOperation(id:"new",externalID:"synthetic:new",action:.create,target:reference,baseline:nil,
            changes:["title":"new ordinary reminder","notes":"new notes","dueDate":"2026-10-11","priority":"0"],recurrenceScope:"this",relationshipScope:"none",notesMode:.replace)
        try AgendaWorkflowCodec.validateOperation(value)
        let native = NativeReminderSimulation(); try AgendaNativeReminderPatch.apply(value,to:native)
        #expect(native.notes == "new notes" && !native.isCompleted && native.dueDateComponents?.hour == nil)
        value.changes["isCompleted"] = "true"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(value) }
    }
    @Test func legacyEncodingAndCalendarHashRemainUnchangedWithAbsentNewKeys() throws {
        let value = op(record(),changes:["title":"new"]), encoded = try AgendaWorkflowCodec.data(value)
        let object = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        #expect(object["reminderStandaloneReview"] == nil)
        #expect(try AgendaWorkflowCodec.hash(JSONDecoder().decode(AgendaOperation.self,from:encoded)) == AgendaWorkflowCodec.hash(value))
    }
}
