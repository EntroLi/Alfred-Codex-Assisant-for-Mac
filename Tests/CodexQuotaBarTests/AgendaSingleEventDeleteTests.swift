import Foundation
import Testing
@testable import CodexQuotaBar

private final class DeleteStore: AgendaWorkflowStore {
    var records: [String: AgendaRecord] = [:]
    var writes = 0
    var loseDeleteResponse = false
    func read(_ reference: AgendaReference) throws -> AgendaRecord? { records[reference.appleID] }
    func read(_ reference: AgendaReference, projectedFields: [String]) throws -> AgendaRecord? { records[reference.appleID] }
    func candidates(for operation: AgendaOperation) throws -> [AgendaRecord] { [] }
    func apply(_ operation: AgendaOperation) throws -> AgendaReference {
        writes += 1
        if operation.action == .delete {
            records.removeValue(forKey: operation.target.appleID)
            if loseDeleteResponse { throw AgendaWorkflowError.invalid("Response lost after deletion") }
        } else {
            var updated = operation.baseline!
            updated.fields = AgendaWorkflowCodec.expectedFields(operation)
            updated.modifiedAt = "synthetic-version-2"
            records[operation.target.appleID] = updated
        }
        return operation.target
    }
}

struct AgendaSingleEventDeleteTests {
    private func operation(_ store: DeleteStore) -> AgendaOperation {
        let reference = AgendaReference(entity: .event, sourceID: "synthetic-source", calendarID: "synthetic-calendar",
            appleID: "target", occurrenceStart: "2026-10-08T11:00:00Z")
        let target = AgendaRecord(reference: reference, modifiedAt: "synthetic-version-1", recurring: false, hasAttendees: false,
            fields: ["title": "target", "start": "2026-10-08T11:00:00Z", "end": "2026-10-08T13:00:00Z",
                     "allDay": "false", "timeZone": "Asia/Shanghai", "location": "synthetic venue"], projectedFields: ["location"])
        var other = target; other.reference.appleID = "other"
        store.records = ["target": target, "other": other]
        return AgendaOperation(id: "delete", externalID: "synthetic:target", action: .delete,
            target: target.reference, baseline: target, changes: [:], recurrenceScope: "this", relationshipScope: "none")
    }
    private func source() -> AgendaSourceVersion {
        AgendaSourceVersion(pageID: "synthetic-page", version: "1", readAt: AgendaWorkflowCodec.now(), contentSHA256: String(repeating: "a", count: 64))
    }
    private func batch(_ operation: AgendaOperation) -> AgendaBatch {
        AgendaBatch(batchID: UUID().uuidString, source: source(), timeZone: "Asia/Shanghai", operations: [operation])
    }
    private func approval(_ preview: AgendaPreview) -> AgendaApproval {
        AgendaApproval(batchID: preview.batch.batchID, previewSHA256: preview.previewSHA256, operationIDs: preview.batch.operations.map(\.id),
            approvedBy: "human-user", approvedAt: AgendaWorkflowCodec.now(), statement: "Approve exactly these operations and fields")
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("agenda-delete-" + UUID().uuidString) }

    @Test func deletionRequiresExplicitAcknowledgementAndSingleEventScope() throws {
        let store = DeleteStore(); var op = operation(store)
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(op) }
        op.allowIrrecoverableDelete = true; try AgendaWorkflowCodec.validateOperation(op)
        op.recurrenceScope = "future"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(op) }
        op.recurrenceScope = "this"; op.baseline?.recurring = true
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(op) }
    }

    @Test func lostDeleteResponseReconcilesAbsenceWithoutRepeatingDelete() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeleteStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: folder))
        var op = operation(store); op.allowIrrecoverableDelete = true
        store.loseDeleteResponse = true
        let preview = try engine.preview(batch(op))
        #expect(preview.rows[0].after == nil && preview.rows[0].reason?.contains("not guaranteed") == true)
        let first = try engine.execute(preview, approval: approval(preview), sourceNow: { source() })
        #expect(first.results[0].status == "unknown" && store.writes == 1)
        let recovered = try engine.readReceipt(preview.batch.batchID)
        #expect(recovered.results[0].status == "success" && store.writes == 1)
        #expect(store.records["target"] == nil && store.records["other"] != nil)
        _ = try engine.execute(preview, approval: nil, sourceNow: { source() })
        #expect(store.writes == 1)
    }

    @Test func invitationsRemindersAndMixedPatchesAreRejected() throws {
        let store = DeleteStore(); var op = operation(store); op.allowIrrecoverableDelete = true
        op.baseline?.hasAttendees = true
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(op) }
        op = operation(store); op.allowIrrecoverableDelete = true; op.target.entity = .reminder; op.baseline?.reference = op.target
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(op) }
        op = operation(store); op.allowIrrecoverableDelete = true; op.changes["title"] = "mixed patch"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validateOperation(op) }
    }

    @Test func missingApprovalAndChangedBaselineNeverDelete() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeleteStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: folder))
        var op = operation(store); op.allowIrrecoverableDelete = true
        let preview = try engine.preview(batch(op))
        #expect(throws: (any Error).self) { try engine.execute(preview, approval: nil, sourceNow: { source() }) }
        store.records["target"]?.modifiedAt = "phone-edit"
        #expect(throws: (any Error).self) { try engine.execute(preview, approval: approval(preview), sourceNow: { source() }) }
        #expect(store.writes == 0 && store.records["target"] != nil && store.records["other"] != nil)
    }

    @Test func legacyOptionalEncodingRemainsAbsent() throws {
        let store = DeleteStore(); var op = operation(store)
        op.action = .update; op.changes = ["location": "new text"]
        let data = try AgendaWorkflowCodec.data(op), decoded = try JSONDecoder().decode(AgendaOperation.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["allowIrrecoverableDelete"] == nil)
        #expect(try AgendaWorkflowCodec.hash(decoded) == AgendaWorkflowCodec.hash(op))
    }
}
