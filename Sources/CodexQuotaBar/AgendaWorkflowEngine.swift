import Foundation
import Darwin

final class AgendaWorkflowLedger {
    private let root: URL
    private var lockFD: Int32 = -1
    init(root: URL) { self.root = root }
    deinit { unlock() }
    private func key(_ batchID: String) throws -> URL {
        root.appendingPathComponent(try AgendaWorkflowCodec.hash(batchID) + ".json")
    }
    func load(_ batchID: String) throws -> AgendaReceipt? {
        let path = try key(batchID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(AgendaReceipt.self, from: Data(contentsOf: path))
    }
    func mapped(_ externalID: String) throws -> AgendaReference? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        var references: [AgendaReference] = []
        var moves: [(AgendaReference, AgendaReference)] = []
        for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where path.pathExtension == "json" {
            let receipt = try JSONDecoder().decode(AgendaReceipt.self, from: Data(contentsOf: path))
            if let reference = receipt.mappings[externalID] {
                if !references.contains(reference) { references.append(reference) }
                if let operation = receipt.batch.operations.first(where: { $0.externalID == externalID && $0.action == .update }),
                   operation.target != reference { moves.append((operation.target, reference)) }
            }
        }
        let terminals = references.filter { reference in !moves.contains { $0.0 == reference } }
        guard terminals.count <= 1, references.isEmpty || !terminals.isEmpty else {
            throw AgendaWorkflowError.invalid("Conflicting mapping for external stable identifier")
        }
        return terminals.first
    }
    func lock() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { throw AgendaWorkflowError.invalid("Ledger symlink paths rejected") }
        lockFD = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            unlock(); throw AgendaWorkflowError.invalid("Another manual batch is running; no writes attempted")
        }
    }
    func unlock() { if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 } }
    func save(_ receipt: AgendaReceipt) throws {
        guard lockFD >= 0 else { throw AgendaWorkflowError.invalid("Ledger lock required") }
        let path = try key(receipt.batch.batchID)
        try AgendaWorkflowCodec.data(receipt).write(to: path, options: .atomic)
        _ = chmod(path.path, 0o600)
        let file = open(path.path, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw AgendaWorkflowError.invalid("Cannot sync receipt") }
        let synced = fsync(file); close(file)
        guard synced == 0 else { throw AgendaWorkflowError.invalid("Cannot sync receipt") }
        let directory = open(root.path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
}

final class AgendaWorkflowEngine {
    private let store: AgendaWorkflowStore
    private let ledger: AgendaWorkflowLedger
    init(store: AgendaWorkflowStore, ledger: AgendaWorkflowLedger) { self.store = store; self.ledger = ledger }

    private func inspect(_ operation: AgendaOperation) throws -> AgendaPreviewRow {
        if let mapped = try ledger.mapped(operation.externalID), mapped != operation.target {
            throw AgendaWorkflowError.invalid("External identifier is already mapped; do not recreate or rebind automatically")
        }
        if operation.action == .create {
            let candidates = try store.candidates(for: operation)
            guard candidates.isEmpty else { throw AgendaWorkflowError.invalid("Creation has deduplication candidates; identity requires user review") }
        } else {
            guard let current = try store.read(operation.target, projectedFields: AgendaWorkflowCodec.projection(operation)), current == operation.baseline else {
                throw AgendaWorkflowError.invalid("Target missing or changed since baseline; preview again")
            }
        }
        return AgendaPreviewRow(operationID: operation.id, before: operation.baseline?.fields,
            after: operation.action == .delete ? nil : AgendaWorkflowCodec.expectedFields(operation), state: "ready", reason: nil, textDifferences: AgendaWorkflowCodec.textDifferences(operation))
    }

    func preview(_ batch: AgendaBatch) throws -> AgendaPreview {
        try AgendaWorkflowCodec.validate(batch)
        if let previous = try ledger.load(batch.batchID) {
            guard previous.batch == batch else { throw AgendaWorkflowError.invalid("Batch ID reused with different content") }
            return AgendaPreview(batch: batch, previewSHA256: previous.previewSHA256, previewedAt: AgendaWorkflowCodec.now(),
                rows: previous.results.map { AgendaPreviewRow(operationID: $0.operationID, before: nil, after: $0.readback?.fields, state: "already-submitted:" + $0.status, reason: "Read receipt and reconcile; do not replay") })
        }
        let rows = batch.operations.map { operation -> AgendaPreviewRow in
            do { return try inspect(operation) }
            catch { return AgendaPreviewRow(operationID: operation.id, before: operation.baseline?.fields,
                after: operation.action == .delete ? nil : AgendaWorkflowCodec.expectedFields(operation), state: "blocked", reason: String(describing: error), textDifferences: AgendaWorkflowCodec.textDifferences(operation)) }
        }
        return AgendaPreview(batch: batch, previewSHA256: try AgendaWorkflowCodec.hash(batch), previewedAt: AgendaWorkflowCodec.now(), rows: rows)
    }

    func execute(_ preview: AgendaPreview, approval: AgendaApproval?, sourceNow: () throws -> AgendaSourceVersion) throws -> AgendaReceipt {
        try AgendaWorkflowCodec.validate(preview.batch)
        let batch = preview.batch
        let digest = try AgendaWorkflowCodec.hash(batch)
        guard preview.previewSHA256 == digest else { throw AgendaWorkflowError.invalid("Preview hash does not match batch") }
        // An already-submitted exact batch uses its stored approval and only rereads.
        // It never needs a renewed approval just to report the prior execution.
        if let previous = try ledger.load(batch.batchID) {
            guard previous.batch == batch else { throw AgendaWorkflowError.invalid("Batch ID reused with different content") }
            try ledger.lock(); defer { ledger.unlock() }
            guard let latest = try ledger.load(batch.batchID), latest.batch == batch else {
                throw AgendaWorkflowError.invalid("Receipt changed during lookup")
            }
            return try reconcile(latest)
        }
        guard let approval, approval.batchID == batch.batchID, approval.previewSHA256 == digest,
              preview.previewSHA256 == digest, approval.approvedBy == "human-user",
              approval.statement == "Approve exactly these operations and fields",
              !approval.operationIDs.isEmpty, Set(approval.operationIDs).count == approval.operationIDs.count,
              Set(approval.operationIDs).isSubset(of: Set(batch.operations.map(\.id))) else {
            throw AgendaWorkflowError.invalid("A specific human approval set matching the preview is required")
        }
        try ledger.lock(); defer { ledger.unlock() }
        if let previous = try ledger.load(batch.batchID) {
            guard previous.batch == batch else { throw AgendaWorkflowError.invalid("Batch changed; use a new batch") }
            // Duplicate submissions never write, even when partially successful or unknown.
            return try reconcile(previous)
        }
        let age = Date().timeIntervalSince(try AgendaWorkflowCodec.date(preview.previewedAt))
        let approvalAge = Date().timeIntervalSince(try AgendaWorkflowCodec.date(approval.approvedAt))
        guard (-60...900).contains(age), (-60...3600).contains(approvalAge) else {
            throw AgendaWorkflowError.invalid("Preview/approval expired; preview and approve again")
        }
        var receipt = AgendaReceipt(batch: batch, previewSHA256: digest, approval: approval,
            device: ProcessInfo.processInfo.hostName, startedAt: AgendaWorkflowCodec.now(),
            results: batch.operations.map { AgendaOperationReceipt(operationID: $0.id,
                status: approval.operationIDs.contains($0.id) ? "pending" : "skipped", appleReference: nil, readback: nil,
                reason: approval.operationIDs.contains($0.id) ? nil : "Outside approved subset") })
        // Preflight every approved row before the first write; one conflict invalidates this preview.
        try verifySource(batch.source, sourceNow())
        for operation in batch.operations where approval.operationIDs.contains(operation.id) {
            guard preview.rows.contains(where: { $0.operationID == operation.id && $0.state == "ready" }) else {
                throw AgendaWorkflowError.invalid("Approved operation is not ready in preview")
            }
            _ = try inspect(operation)
        }
        try ledger.save(receipt)
        for (index, operation) in batch.operations.enumerated() where approval.operationIDs.contains(operation.id) {
            do {
                let currentSource = try sourceNow(); try verifySource(batch.source, currentSource)
                receipt.sourceVerifiedAt = currentSource.readAt
                _ = try inspect(operation)
            } catch {
                receipt.results[index].status = "skipped"; receipt.results[index].reason = String(describing: error)
                // Changes during execution require a fresh preview for all remaining writes.
                for rest in batch.operations.indices where rest > index && receipt.results[rest].status == "pending" {
                    receipt.results[rest].status = "skipped"; receipt.results[rest].reason = "Batch halted after changed precondition"
                }
                break
            }
            // Persist uncertainty BEFORE invoking Apple. A crash may have committed a write.
            receipt.results[index].status = "unknown"
            receipt.results[index].reason = "Write boundary entered; must read back before any retry"
            try ledger.save(receipt)
            do {
                let reference = try store.apply(operation)
                receipt.results[index].appleReference = reference
                receipt.mappings[operation.externalID] = reference
                try ledger.save(receipt)
                let current = try store.read(reference, projectedFields: AgendaWorkflowCodec.projection(operation))
                receipt.results[index].readback = current
                if operation.action == .delete ? current == nil : AgendaWorkflowCodec.confirms(current, operation: operation, reference: reference) {
                    receipt.results[index].status = "success"; receipt.results[index].reason = nil
                } else { receipt.results[index].reason = "Apple returned, but actual readback differs; no blind retry" }
            } catch { receipt.results[index].reason = String(describing: error) }
            try ledger.save(receipt)
            if receipt.results[index].status == "unknown" {
                for rest in batch.operations.indices where rest > index && receipt.results[rest].status == "pending" {
                    receipt.results[rest].status = "skipped"; receipt.results[rest].reason = "Batch halted after unknown result"
                }
                break
            }
        }
        receipt.finishedAt = AgendaWorkflowCodec.now(); try ledger.save(receipt); return receipt
    }

    private func verifySource(_ expected: AgendaSourceVersion, _ current: AgendaSourceVersion) throws {
        let age = Date().timeIntervalSince(try AgendaWorkflowCodec.date(current.readAt))
        guard current.pageID == expected.pageID, current.version == expected.version,
              current.contentSHA256 == expected.contentSHA256, (-60...120).contains(age) else {
            throw AgendaWorkflowError.invalid("Source changed or current read proof stale; preview again")
        }
    }

    func readReceipt(_ batchID: String) throws -> AgendaReceipt {
        try ledger.lock(); defer { ledger.unlock() }
        guard let receipt = try ledger.load(batchID) else { throw AgendaWorkflowError.invalid("Receipt not found") }
        return try reconcile(receipt)
    }

    private func reconcile(_ previous: AgendaReceipt) throws -> AgendaReceipt {
        var receipt = previous
        for (index, operation) in receipt.batch.operations.enumerated() {
            guard ["success", "unknown"].contains(receipt.results[index].status) else { continue }
            do {
                guard let reference = receipt.results[index].appleReference ?? (operation.action == .create ? nil : operation.target) else {
                    let candidates = try store.candidates(for: operation)
                    receipt.results[index].recoveryCandidates = candidates
                    receipt.results[index].reason = "Unknown creation; \(candidates.count) candidates read, no automatic binding or retry"
                    continue
                }
                let current = try store.read(reference, projectedFields: AgendaWorkflowCodec.projection(operation)); receipt.results[index].readback = current
                if operation.action == .delete ? current == nil : AgendaWorkflowCodec.confirms(current, operation: operation, reference: reference) {
                    receipt.results[index].status = "success"; receipt.results[index].appleReference = reference
                    receipt.mappings[operation.externalID] = reference
                    receipt.results[index].reason = "Already executed; current fields verified; no write repeated"
                } else if receipt.results[index].status == "success" {
                    // Retain historical success, distinguish subsequent user edits in current readback.
                    receipt.results[index].reason = "Previously verified success; current target changed or is missing; no overwrite"
                } else { receipt.results[index].reason = "Unknown result; current state does not confirm intended outcome; no retry" }
            } catch { receipt.results[index].reason = "Current readback failed: " + String(describing: error) }
        }
        receipt.finishedAt = AgendaWorkflowCodec.now(); try ledger.save(receipt); return receipt
    }
}
