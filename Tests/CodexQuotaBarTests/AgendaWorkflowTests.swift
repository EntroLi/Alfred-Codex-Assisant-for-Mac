import Foundation
import Testing
@testable import CodexQuotaBar

private final class WorkflowFakeStore: AgendaWorkflowStore {
    var records: [String: AgendaRecord] = [:]
    var writeCount = 0
    var throwAfterCommit = false
    var alterReadback = false
    var rejectCandidates = false
    func read(_ reference: AgendaReference) throws -> AgendaRecord? { records[reference.appleID] }
    func candidates(for operation: AgendaOperation) throws -> [AgendaRecord] {
        if rejectCandidates { throw AgendaWorkflowError.invalid("Read failed; not zero candidates") }
        return records.values.filter { $0.reference.calendarID == operation.target.calendarID && $0.fields["title"] == operation.changes["title"] }
    }
    func apply(_ operation: AgendaOperation) throws -> AgendaReference {
        writeCount += 1
        var reference = operation.target
        if operation.action == .create { reference.appleID = "fake-" + String(writeCount) }
        if operation.action == .delete { records.removeValue(forKey: reference.appleID) }
        else {
            var fields = AgendaWorkflowCodec.expectedFields(operation)
            if alterReadback { fields["title"] = "unexpected normalization" }
            records[reference.appleID] = AgendaRecord(reference: reference, appleExternalID: "fake-external",
                modifiedAt: "fake-version-2", recurring: false, hasAttendees: false, fields: fields)
        }
        if throwAfterCommit { throw AgendaWorkflowError.invalid("Simulated lost response after commit") }
        return reference
    }
}

struct AgendaWorkflowTests {
    private func source() -> AgendaSourceVersion {
        AgendaSourceVersion(pageID: "page_synthetic", version: "1", readAt: AgendaWorkflowCodec.now(), contentSHA256: String(repeating: "a", count: 64))
    }
    private func create(_ id: String = "one") -> AgendaOperation {
        AgendaOperation(id: id, externalID: "synthetic:" + id, action: .create,
            target: AgendaReference(entity: .reminder, sourceID: "fake-source", calendarID: "fake-list", appleID: "", occurrenceStart: nil),
            baseline: nil, changes: ["title": "synthetic " + id, "dueDate": "2026-10-06"], recurrenceScope: "this", relationshipScope: "none")
    }
    private func batch(_ operations: [AgendaOperation]) -> AgendaBatch {
        AgendaBatch(batchID: UUID().uuidString, source: source(), timeZone: "Asia/Shanghai", operations: operations)
    }
    private func approval(_ preview: AgendaPreview, subset: [String]? = nil) -> AgendaApproval {
        AgendaApproval(batchID: preview.batch.batchID, previewSHA256: preview.previewSHA256,
            operationIDs: subset ?? preview.batch.operations.map(\.id), approvedBy: "human-user",
            approvedAt: AgendaWorkflowCodec.now(), statement: "Approve exactly these operations and fields")
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("alfred-agenda-test-" + UUID().uuidString) }
    private func modified(_ store: WorkflowFakeStore) -> AgendaOperation {
        let reference = AgendaReference(entity: .reminder, sourceID: "fake-source", calendarID: "fake-list", appleID: "existing", occurrenceStart: nil)
        let baseline = AgendaRecord(reference: reference, appleExternalID: "external-original", modifiedAt: "fake-version-1", recurring: false,
            hasAttendees: false, fields: ["title": "old", "priority": "1", "isCompleted": "false", "dueDate": "", "dueTime": "", "dueTimeZone": ""])
        store.records[reference.appleID] = baseline
        return AgendaOperation(id: "one", externalID: "synthetic:existing", action: .update, target: reference, baseline: baseline,
            changes: ["title": "new"], recurrenceScope: "this", relationshipScope: "none")
    }

    @Test func previewCannotWriteAndMissingApprovalCreatesNoLedger() throws {
        let root = folder(), store = WorkflowFakeStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([create()]))
        #expect(preview.rows[0].state == "ready")
        #expect(throws: (any Error).self) { try engine.execute(preview, approval: nil, sourceNow: { source() }) }
        #expect(store.writeCount == 0 && !FileManager.default.fileExists(atPath: root.path))
    }

    @Test func approvalBindsFieldsAndSubsetAndDuplicateBatchOnlyReads() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([create(), create("two")]))
        let approved = approval(preview, subset: ["one"])
        let first = try engine.execute(preview, approval: approved, sourceNow: { source() })
        #expect(first.results.map(\.status) == ["success", "skipped"] && store.writeCount == 1)
        let again = try engine.execute(preview, approval: approved, sourceNow: { throw AgendaWorkflowError.invalid("Must not require fresh source to report already executed") })
        #expect(again.results[0].status == "success" && store.writeCount == 1)
        #expect(again.results[0].reason?.contains("Already executed") == true)
        let noRenewal = try engine.execute(preview, approval: nil, sourceNow: { source() })
        #expect(noRenewal.results[0].status == "success" && store.writeCount == 1)
        var tampered = preview; tampered.batch.operations[0].changes["title"] = "unapproved"
        #expect(throws: (any Error).self) { try engine.execute(tampered, approval: approved, sourceNow: { source() }) }
        #expect(store.writeCount == 1)
    }

    @Test func phoneChangesAndMissingIdentifiersBlockAllWrites() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let operation = modified(store), preview = try engine.preview(batch([operation]))
        store.records["existing"]?.modifiedAt = "phone-new-version"
        #expect(throws: (any Error).self) { try engine.execute(preview, approval: approval(preview), sourceNow: { source() }) }
        #expect(store.writeCount == 0)
        store.records.removeAll()
        #expect(try engine.preview(preview.batch).rows[0].state == "blocked")
    }

    @Test func sourceChangeBeforeFirstWriteInvalidatesPreview() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([create()]))
        var changed = source(); changed.version = "2"
        #expect(throws: (any Error).self) { try engine.execute(preview, approval: approval(preview), sourceNow: { changed }) }
        #expect(store.writeCount == 0)
    }

    @Test func sourceChangeMidBatchStopsRemainingOperations() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([create(), create("two")]))
        var calls = 0
        let result = try engine.execute(preview, approval: approval(preview), sourceNow: {
            calls += 1; var proof = source(); if calls >= 3 { proof.version = "2" }; return proof
        })
        #expect(result.results.map(\.status) == ["success", "skipped"] && store.writeCount == 1)
    }

    @Test func unknownCreationReadsCandidatesButNeverRetriesOrBindsByTitle() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(); store.throwAfterCommit = true
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([create(), create("two")]))
        let approved = approval(preview)
        let first = try engine.execute(preview, approval: approved, sourceNow: { source() })
        #expect(first.results.map(\.status) == ["unknown", "skipped"] && store.writeCount == 1)
        let again = try engine.execute(preview, approval: approved, sourceNow: { source() })
        #expect(again.results[0].status == "unknown" && again.results[0].appleReference == nil)
        #expect(again.results[0].reason?.contains("1 candidates") == true && store.writeCount == 1)
    }

    @Test func lostUpdateResponseCanBeConfirmedByReadbackWithoutRetry() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(), operation = modified(store); store.throwAfterCommit = true
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([operation])), approved = approval(preview)
        #expect(try engine.execute(preview, approval: approved, sourceNow: { source() }).results[0].status == "unknown")
        let again = try engine.execute(preview, approval: approved, sourceNow: { source() })
        #expect(again.results[0].status == "success" && store.writeCount == 1)
        #expect(again.results[0].readback?.fields["isCompleted"] == "false" && again.results[0].readback?.fields["priority"] == "1")
    }

    @Test func changedReadbackIsUnknownAndLaterPhoneChangesAreNotOverwritten() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(); store.alterReadback = true
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([create()])), approved = approval(preview)
        let first = try engine.execute(preview, approval: approved, sourceNow: { source() })
        #expect(first.results[0].status == "unknown" && first.results[0].appleReference != nil)
        let again = try engine.execute(preview, approval: approved, sourceNow: { source() })
        #expect(again.results[0].status == "unknown" && store.writeCount == 1)
    }

    @Test func sameTitleIsOnlyAReviewCandidateAndReadFailureIsNotEmpty() throws {
        let root = folder(), store = WorkflowFakeStore()
        let existing = modified(store); store.records[existing.target.appleID]?.fields["title"] = "synthetic one"
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        #expect(try engine.preview(batch([create()])).rows[0].state == "blocked")
        store.records.removeAll(); store.rejectCandidates = true
        #expect(try engine.preview(batch([create()])).rows[0].state == "blocked")
        #expect(store.writeCount == 0)
    }

    @Test func dateOnlyAndFloatingTimeRetainNativeComponents() throws {
        let due = try AgendaDateComponents.parse(date: "2026-10-06", time: "", zone: "")
        #expect(due?.hour == nil && due?.minute == nil && due?.second == nil && due?.timeZone == nil)
        let timed = try AgendaDateComponents.parse(date: "2026-10-06", time: "09:30:15", zone: "")
        #expect(timed?.second == 15 && timed?.timeZone == nil)
        #expect(try AgendaDateComponents.parse(date: "", time: "", zone: "") == nil)
        #expect(throws: (any Error).self) { try AgendaDateComponents.parse(date: "2026-02-30", time: "", zone: "") }
        #expect(throws: (any Error).self) { try AgendaDateComponents.parse(date: "", time: "00:00", zone: "") }
    }

    @Test func unsafeSeriesCompletionAndParentChildFieldsAreRejected() throws {
        let store = WorkflowFakeStore(); var operation = modified(store)
        operation.recurrenceScope = "series"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch([operation])) }
        operation.recurrenceScope = "this"; operation.changes["isCompleted"] = "true"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch([operation])) }
        operation.changes = ["title": "new"]; operation.relationshipScope = "children"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch([operation])) }
        operation.relationshipScope = "none"; operation.baseline?.recurring = true
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch([operation])) }
    }

    @Test func mappedExternalIdentifierCannotBeRecreatedInNewBatch() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(), engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch([create()]))
        _ = try engine.execute(preview, approval: approval(preview), sourceNow: { source() })
        store.records.removeAll()
        #expect(try engine.preview(batch([create()])).rows[0].state == "blocked")
        #expect(store.writeCount == 1)
    }

    @Test func localLockPreventsParallelExecution() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let first = AgendaWorkflowLedger(root: root), second = AgendaWorkflowLedger(root: root)
        try first.lock(); defer { first.unlock() }
        #expect(throws: (any Error).self) { try second.lock() }
    }

    @Test func sixYearReadHasNoFourYearTruncationOrBoundaryGaps() throws {
        let start = try AgendaWorkflowCodec.date("2023-10-04T16:00:00Z"), end = try AgendaWorkflowCodec.date("2029-10-04T16:00:00Z")
        let windows = try AgendaEventWindows.segments(start: start, end: end, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(windows.count == 6 && windows.first?.0 == start && windows.last?.1 == end)
        for index in 1..<windows.count { #expect(windows[index - 1].1 == windows[index].0) }
        #expect(windows.allSatisfy { $0.0 < $0.1 && $0.1.timeIntervalSince($0.0) <= 366 * 86400 })
        #expect(throws: (any Error).self) { try AgendaEventWindows.segments(start: end, end: start, timeZone: TimeZone(secondsFromGMT: 0)!) }
    }

    @Test func approvedMappingMoveHasOneTerminalAndUnknownForkStops() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkflowFakeStore(), operation = modified(store)
        let ledger = AgendaWorkflowLedger(root: root)
        var moved = operation.target; moved.appleID = "moved-identifier"
        let value = batch([operation]), preview = AgendaPreview(batch: value, previewSHA256: try AgendaWorkflowCodec.hash(value),
            previewedAt: AgendaWorkflowCodec.now(), rows: [])
        let receipt = AgendaReceipt(batch: value, previewSHA256: preview.previewSHA256, approval: approval(preview), device: "synthetic",
            startedAt: AgendaWorkflowCodec.now(), results: [], mappings: [operation.externalID: operation.target])
        try ledger.lock(); defer { ledger.unlock() }
        try ledger.save(receipt)
        var second = receipt; second.batch.batchID = UUID().uuidString; second.mappings[operation.externalID] = moved
        try ledger.save(second)
        #expect(try ledger.mapped(operation.externalID) == moved)
        var forked = second; forked.batch.batchID = UUID().uuidString
        var fork = moved; fork.appleID = "ambiguous-fork"; forked.mappings[operation.externalID] = fork
        try ledger.save(forked)
        #expect(throws: (any Error).self) { try ledger.mapped(operation.externalID) }
    }
}
