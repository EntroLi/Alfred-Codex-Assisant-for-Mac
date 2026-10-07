import Foundation
import Testing
@testable import CodexQuotaBar

// No EKEventStore, permissions, Apple reads or writes in this suite.
private final class FiveFieldStore: AgendaWorkflowStore {
    var records: [String: AgendaRecord] = [:]
    var writes = 0
    var projections: [[String]] = []
    var loseResponse = false
    var normalizeEmptyToNil = false
    var unrelated = ["URL": "https://example.invalid", "alarms": "original", "availability": "original", "organizer": "original"]
    func read(_ reference: AgendaReference) throws -> AgendaRecord? { try read(reference, projectedFields: []) }
    func read(_ reference: AgendaReference, projectedFields: [String]) throws -> AgendaRecord? {
        projections.append(projectedFields)
        guard var value = records[reference.appleID], value.reference == reference else { return nil }
        for field in AgendaWorkflowCodec.textFields where !projectedFields.contains(field) { value.fields.removeValue(forKey: field) }
        value.projectedFields = projectedFields.isEmpty ? nil : projectedFields
        return value
    }
    func candidates(for operation: AgendaOperation) throws -> [AgendaRecord] {
        try records.values.filter { $0.reference.calendarID == operation.target.calendarID && $0.fields["title"] == operation.changes["title"] }
            .compactMap { try read($0.reference) }
    }
    func apply(_ operation: AgendaOperation) throws -> AgendaReference {
        try AgendaWorkflowCodec.validateOperation(operation)
        if operation.action == .update {
            guard try read(operation.target, projectedFields: AgendaWorkflowCodec.projection(operation)) == operation.baseline else {
                throw AgendaWorkflowError.invalid("Final simulated conflict")
            }
        }
        writes += 1
        var reference = operation.target
        if reference.appleID.isEmpty { reference.appleID = "created" }
        let expected = AgendaWorkflowCodec.expectedFields(operation)
        reference.occurrenceStart = expected["start"]
        var fields = records[operation.target.appleID]?.fields ?? [:]
        for field in operation.changes.keys { fields[field] = expected[field] }
        for field in operation.clearFields ?? [] { fields.removeValue(forKey: field) }
        if normalizeEmptyToNil { for field in AgendaWorkflowCodec.textFields where fields[field] == "" { fields.removeValue(forKey: field) } }
        records[reference.appleID] = AgendaRecord(reference: reference, appleExternalID: "external", modifiedAt: "new-version",
            recurring: false, hasAttendees: false, fields: fields)
        if loseResponse { throw AgendaWorkflowError.invalid("SIMULATED timeout after save") }
        return reference
    }
}

private final class TextItem: AgendaNativeTextItem {
    var location: String? = "Original place" { didSet { locationSets += 1 } }
    var notes: String? = "Original notes" { didSet { notesSets += 1 } }
    var locationSets = 0, notesSets = 0
    let unrelated = ["title": "original", "calendar": "original", "URL": "original", "alarms": "original", "availability": "original", "organizer": "original"]
}

struct AgendaFiveFieldTests {
    private func reference() -> AgendaReference {
        AgendaReference(entity: .event, sourceID: "source", calendarID: "calendar", appleID: "item", occurrenceStart: "2026-10-08T11:00:00Z")
    }
    private func record() -> AgendaRecord {
        AgendaRecord(reference: reference(), appleExternalID: "external", modifiedAt: "2026-10-01T00:00:00.123Z", recurring: false,
            hasAttendees: false, fields: ["title": "Old", "start": "2026-10-08T11:00:00Z", "end": "2026-10-08T13:00:00Z", "allDay": "false", "timeZone": "Asia/Shanghai"])
    }
    private func operation(_ store: FiveFieldStore, changes: [String: String], projection: [String] = ["location", "notes"], notes: String? = "Existing notes", location: String? = "Existing place", mode: AgendaNotesMode? = nil) throws -> AgendaOperation {
        var value = record(); value.fields["notes"] = notes; value.fields["location"] = location
        store.records["item"] = value
        let baseline = try store.read(reference(), projectedFields: projection)
        return AgendaOperation(id: "op", externalID: "synthetic:op", action: .update, target: reference(), baseline: baseline,
            changes: changes, recurrenceScope: "this", relationshipScope: "none", notesMode: mode)
    }
    private func source() -> AgendaSourceVersion {
        AgendaSourceVersion(pageID: "synthetic", version: "1", readAt: AgendaWorkflowCodec.now(), contentSHA256: String(repeating: "a", count: 64))
    }
    private func batch(_ operation: AgendaOperation) -> AgendaBatch {
        AgendaBatch(batchID: UUID().uuidString, source: source(), timeZone: "Asia/Shanghai", operations: [operation])
    }
    private func approval(_ preview: AgendaPreview) -> AgendaApproval {
        AgendaApproval(batchID: preview.batch.batchID, previewSHA256: preview.previewSHA256, operationIDs: ["op"], approvedBy: "human-user",
            approvedAt: AgendaWorkflowCodec.now(), statement: "Approve exactly these operations and fields")
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("alfred-five-field-test-" + UUID().uuidString) }

    @Test func legacyHashAndReceiptRemainCompatible() throws {
        let op = AgendaOperation(id: "op", externalID: "synthetic:op", action: .update, target: reference(), baseline: record(),
            changes: ["title": "New"], recurrenceScope: "this", relationshipScope: "none")
        var src = source(); src.readAt = "2026-10-07T00:00:00Z"
        let old = AgendaBatch(batchID: "legacy-synthetic", source: src, timeZone: "Asia/Shanghai", operations: [op])
        // Captured by the PRE-CHANGE codec, using synthetic data only.
        #expect(try AgendaWorkflowCodec.hash(old) == "90bee3d2135756210aafd25350aad0cf7591d4ea99998b80ac4ada49395f776e")
        let data = try AgendaWorkflowCodec.data(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("projectedFields"))
        #expect(!String(decoding: data, as: UTF8.self).contains("notesMode"))
        #expect(!String(decoding: data, as: UTF8.self).contains("clearFields"))
        #expect(try JSONDecoder().decode(AgendaBatch.self, from: data) == old)
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgendaWorkflowLedger(root: root)
        let preview = AgendaPreview(batch: old, previewSHA256: try AgendaWorkflowCodec.hash(old), previewedAt: AgendaWorkflowCodec.now(), rows: [])
        let receipt = AgendaReceipt(batch: old, previewSHA256: preview.previewSHA256, approval: approval(preview), device: "synthetic",
            startedAt: AgendaWorkflowCodec.now(), results: [AgendaOperationReceipt(operationID: "op", status: "success", appleReference: reference(), readback: record(), reason: nil)], mappings: [op.externalID: reference()])
        try ledger.lock(); try ledger.save(receipt); ledger.unlock()
        #expect(try ledger.load(old.batchID)?.batch == old)
        #expect(try ledger.mapped(op.externalID) == reference())
    }

    @Test func exactReadScopeRejectsMissingIdentityUnsupportedFieldsAndReminders() throws {
        try AgendaTargetReadRequest(targets: [reference()], fields: ["notes"]).validate()
        var missing = reference(); missing.appleID = ""
        var reminder = reference(); reminder.entity = .reminder
        for request in [AgendaTargetReadRequest(targets: [missing], fields: ["notes"]),
                        AgendaTargetReadRequest(targets: [reminder], fields: ["notes"]),
                        AgendaTargetReadRequest(targets: [reference()], fields: ["URL"]),
                        AgendaTargetReadRequest(targets: [reference(), reference()], fields: ["notes"]),
                        AgendaTargetReadRequest(targets: [reference()], fields: [])] {
            #expect(throws: (any Error).self) { try request.validate() }
        }
    }

    @Test func explicitProjectionIsRequiredAndUnselectedNotesNeverRead() throws {
        let store = FiveFieldStore()
        let op = try operation(store, changes: ["location": "New place"], projection: ["location"])
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch(op))
        #expect(preview.rows[0].before?["notes"] == nil && preview.rows[0].state == "ready")
        #expect(store.projections.allSatisfy { $0 == ["location"] })
        var unread = op; unread.baseline?.projectedFields = nil; unread.baseline?.fields.removeValue(forKey: "location")
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(unread)) }
        #expect(store.writes == 0)
    }

    @Test func appendPreviewShowsExactMergeAndApprovalBindsModeAndText() throws {
        let store = FiveFieldStore(), root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let op = try operation(store, changes: ["notes": "New responsibility"], projection: ["notes"], mode: .append)
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root))
        let preview = try engine.preview(batch(op)), diff = try #require(preview.rows[0].textDifferences?.first)
        #expect(diff.mode == "append" && diff.before == "Existing notes" && diff.after == "Existing notes\n\nNew responsibility")
        #expect(store.writes == 0)
        for mode in [AgendaNotesMode.replace, .append] {
            var changed = preview; changed.batch.operations[0].notesMode = mode; changed.batch.operations[0].changes["notes"] = "Tampered"
            #expect(throws: (any Error).self) { try engine.execute(changed, approval: approval(preview), sourceNow: { source() }) }
        }
        let first = try engine.execute(preview, approval: approval(preview), sourceNow: { source() })
        #expect(first.results[0].status == "success" && first.results[0].readback?.fields["notes"] == diff.after)
        #expect(store.records["item"]?.fields["location"] == "Existing place" && store.unrelated["alarms"] == "original")
        let repeatReceipt = try engine.execute(preview, approval: nil, sourceNow: { source() })
        #expect(repeatReceipt.results[0].status == "success" && store.writes == 1)
    }

    @Test func textAndVersionAndCategoryConflictsStopBeforeWrite() throws {
        for change in ["notes", "location", "modifiedAt", "calendar", "source"] {
            let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
            let store = FiveFieldStore(), op = try operation(store, changes: ["notes": "Addition"], mode: .append)
            let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root)), preview = try engine.preview(batch(op))
            if change == "modifiedAt" { store.records["item"]?.modifiedAt = "phone-version" }
            else if change == "calendar" { store.records["item"]?.reference.calendarID = "other" }
            else if change == "source" { store.records["item"]?.reference.sourceID = "other" }
            else { store.records["item"]?.fields[change] = "Phone edit" }
            #expect(throws: (any Error).self) { try engine.execute(preview, approval: approval(preview), sourceNow: { source() }) }
            #expect(store.writes == 0)
        }
    }

    @Test func nativeNilEmptyAndClearAreDifferentReviewableOperations() throws {
        for initial in [nil, "", "Existing"] as [String?] {
            let store = FiveFieldStore()
            var op = try operation(store, changes: ["notes": "Addition"], projection: ["notes"], notes: initial, mode: .append)
            try AgendaWorkflowCodec.validate(batch(op))
            #expect(AgendaWorkflowCodec.expectedFields(op)["notes"] == (initial == nil || initial == "" ? "Addition" : "Existing\n\nAddition"))
            op.notesMode = .replace; op.changes = ["notes": ""]
            #expect(AgendaWorkflowCodec.expectedFields(op)["notes"] == "")
            op.changes = [:]; op.clearFields = ["notes"]
            try AgendaWorkflowCodec.validate(batch(op))
            #expect(AgendaWorkflowCodec.expectedFields(op)["notes"] == nil)
            let diff = try #require(AgendaWorkflowCodec.textDifferences(op)?.first)
            let json = try JSONSerialization.jsonObject(with: AgendaWorkflowCodec.data(diff)) as! [String: Any]
            #expect(json["after"] is NSNull && diff.mode == "clear")
            if initial == nil { #expect(json["before"] is NSNull) }
        }
    }

    @Test func setterBoundaryPreservesUntouchedFieldsAndSupportsNativeClear() throws {
        let store = FiveFieldStore(), item = TextItem(), before = item.unrelated
        var op = try operation(store, changes: ["location": "New place"], projection: ["location"])
        AgendaNativeTextPatch.apply(op, to: item)
        #expect(item.location == "New place" && item.locationSets == 1 && item.notesSets == 0 && item.notes == "Original notes")
        op = try operation(store, changes: [:], projection: ["notes"], mode: .replace); op.clearFields = ["notes"]
        try AgendaWorkflowCodec.validate(batch(op)); AgendaNativeTextPatch.apply(op, to: item)
        #expect(item.notes == nil && item.notesSets == 1 && item.locationSets == 1 && item.unrelated == before)
    }

    @Test func nullableNormalizationIsUnknownAndDoesNotReplay() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FiveFieldStore(); store.normalizeEmptyToNil = true
        let op = try operation(store, changes: ["notes": ""], projection: ["notes"], mode: .replace)
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root)), preview = try engine.preview(batch(op))
        #expect(try engine.execute(preview, approval: approval(preview), sourceNow: { source() }).results[0].status == "unknown")
        #expect(try engine.execute(preview, approval: nil, sourceNow: { source() }).results[0].status == "unknown")
        #expect(store.writes == 1)
    }

    @Test func timeoutAfterNotesSaveReconcilesWithoutSecondAppend() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FiveFieldStore(); store.loseResponse = true
        let op = try operation(store, changes: ["notes": "Addition"], projection: ["notes"], mode: .append)
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root)), preview = try engine.preview(batch(op))
        #expect(try engine.execute(preview, approval: approval(preview), sourceNow: { source() }).results[0].status == "unknown")
        #expect(try engine.execute(preview, approval: nil, sourceNow: { source() }).results[0].status == "success")
        #expect(store.writes == 1 && store.records["item"]?.fields["notes"] == "Existing notes\n\nAddition")
    }

    @Test func invitationsSeriesUnsupportedSettersAndDeleteAreRejected() throws {
        let store = FiveFieldStore(), valid = try operation(store, changes: ["location": "New"])
        for field in ["attendees", "organizer", "availability", "URL", "alarms", "calendarID", "sourceID", "status"] {
            var op = valid; op.changes[field] = "unauthorized"
            #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(op)) }
        }
        for recurring in [false, true] {
            var op = valid; op.baseline?.hasAttendees = !recurring; op.baseline?.recurring = recurring
            #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(op)) }
        }
        var op = valid; op.recurrenceScope = "series"
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(op)) }
        op = valid; op.action = .delete; op.changes = [:]
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(op)) }
        #expect(store.writes == 0)
    }

    @Test func malformedTextPatchesAreRejected() throws {
        let store = FiveFieldStore(), valid = try operation(store, changes: ["notes": "Addition"], mode: .append)
        var bad = valid; bad.notesMode = nil
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(bad)) }
        bad = valid; bad.changes["notes"] = ""
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(bad)) }
        bad = valid; bad.clearFields = ["notes"]
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(bad)) }
        bad = valid; bad.clearFields = ["URL"]
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(bad)) }
        bad = valid; bad.baseline?.projectedFields = ["notes", "location"]
        #expect(throws: (any Error).self) { try AgendaWorkflowCodec.validate(batch(bad)) }
    }

    @Test func threeDayAllDayCreationUsesExclusiveOctober20End() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FiveFieldStore(); var ref = reference(); ref.appleID = ""; ref.occurrenceStart = nil
        let op = AgendaOperation(id: "op", externalID: "synthetic:trip", action: .create, target: ref, baseline: nil,
            changes: ["title": "Synthetic three day trip", "start": "2026-10-16T16:00:00Z", "end": "2026-10-19T16:00:00Z", "allDay": "true", "timeZone": "Asia/Shanghai", "location": "Synthetic destination", "notes": "Tentative"], recurrenceScope: "this", relationshipScope: "none", notesMode: .replace)
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root)), preview = try engine.preview(batch(op))
        let result = try engine.execute(preview, approval: approval(preview), sourceNow: { source() })
        let fields = try #require(result.results[0].readback?.fields)
        #expect(result.results[0].status == "success" && fields["allDay"] == "true")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = try AgendaWorkflowCodec.date(fields["start"]!), end = try AgendaWorkflowCodec.date(fields["end"]!)
        #expect(calendar.component(.day, from: start) == 17 && calendar.component(.day, from: end) == 20)
        #expect(calendar.dateComponents([.day], from: start, to: end).day == 3)
        #expect(fields["location"] == "Synthetic destination" && fields["notes"] == "Tentative")
        #expect(result.results[0].appleReference?.calendarID == ref.calendarID)
    }
    @Test func unknownExtendedCreationNeverBindsCandidateOrRetries() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FiveFieldStore(); store.loseResponse = true
        var ref = reference(); ref.appleID = ""; ref.occurrenceStart = nil
        let op = AgendaOperation(id: "op", externalID: "synthetic:unknown-create", action: .create, target: ref, baseline: nil,
            changes: record().fields.merging(["location": "New place", "notes": "New notes"]) { _, new in new },
            recurrenceScope: "this", relationshipScope: "none", notesMode: .replace)
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root)), preview = try engine.preview(batch(op))
        #expect(try engine.execute(preview, approval: approval(preview), sourceNow: { source() }).results[0].status == "unknown")
        let again = try engine.execute(preview, approval: nil, sourceNow: { source() })
        #expect(again.results[0].status == "unknown" && again.results[0].appleReference == nil && store.writes == 1)
        #expect(again.results[0].recoveryCandidates?.count == 1)
        #expect(again.results[0].recoveryCandidates?.first?.fields["notes"] == nil)
        #expect(again.results[0].recoveryCandidates?.first?.projectedFields == nil)
    }

    @Test func movedTimeAndTextReadBackUsingReturnedOccurrenceIdentity() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FiveFieldStore()
        let op = try operation(store, changes: ["title": "Moved", "start": "2026-10-09T11:00:00Z", "end": "2026-10-09T13:00:00Z", "location": "New place", "notes": "New responsibility"], mode: .replace)
        let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: root)), preview = try engine.preview(batch(op))
        let first = try engine.execute(preview, approval: approval(preview), sourceNow: { source() })
        #expect(first.results[0].status == "success" && first.results[0].appleReference?.occurrenceStart == op.changes["start"])
        #expect(first.results[0].appleReference?.calendarID == op.target.calendarID && first.results[0].appleReference?.sourceID == op.target.sourceID)
        #expect(first.results[0].readback?.fields["notes"] == "New responsibility")
        #expect(try engine.execute(preview, approval: nil, sourceNow: { source() }).results[0].status == "success")
        #expect(store.writes == 1)
    }

}
