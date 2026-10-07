import Foundation
import Darwin

enum AgendaWorkflowCLI {
    static func run(_ args: [String]) -> Int32 {
        // On-demand mode exits before NSApplication, timers, notifications or log scanning.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 60) {
            let message = "{\"status\":\"timeout\",\"reason\":\"Hard 60s deadline; if execute entered a write boundary, consult the receipt; never retry blindly\"}\n"
            FileHandle.standardError.write(Data(message.utf8)); exit(2)
        }
        func decode<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        func output<T: Encodable>(_ value: T) throws {
            FileHandle.standardOutput.write(try AgendaWorkflowCodec.data(value)); FileHandle.standardOutput.write(Data("\n".utf8))
        }
        do {
            guard let command = args.first else { throw AgendaWorkflowError.invalid("Use status | inventory | read request.json | read-targets request.json | preview batch.json ledger-dir | execute preview.json approval.json source-current.json ledger-dir | receipt batch-id ledger-dir") }
            let store = AgendaEventKitStore()
            switch command {
            case "status":
                guard args.count == 1 else { throw AgendaWorkflowError.invalid("status takes no arguments") }
                try output(AgendaEventKitStore.permissions())
            case "inventory":
                guard args.count == 1 else { throw AgendaWorkflowError.invalid("inventory takes no arguments") }
                try output(store.inventory())
            case "request-read-access", "request-calendar-access":
                let entities = try AgendaPrivacyCommand.entities(command: command, arguments: args)
                try output(store.requestReadPrivacyAccess(entities: entities))
            case "read":
                guard args.count == 2 else { throw AgendaWorkflowError.invalid("read requires an explicit request file; no implicit all-data read") }
                try output(store.readAll(decode(AgendaReadRequest.self, args[1])))
            case "read-targets":
                guard args.count == 2 else { throw AgendaWorkflowError.invalid("read-targets requires exact event identities and explicit location/notes fields") }
                try output(store.readTargets(decode(AgendaTargetReadRequest.self, args[1])))
            case "preview":
                guard args.count == 3 else { throw AgendaWorkflowError.invalid("preview requires batch and ledger directory") }
                let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: URL(fileURLWithPath: args[2])))
                try output(engine.preview(decode(AgendaBatch.self, args[1])))
            case "execute":
                guard args.count == 5 else { throw AgendaWorkflowError.invalid("execute requires preview, exact human approval, freshly reread source proof and ledger directory") }
                let preview = try decode(AgendaPreview.self, args[1]), approval = try decode(AgendaApproval.self, args[2])
                let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: URL(fileURLWithPath: args[4])))
                let receipt = try engine.execute(preview, approval: approval) {
                    try decode(AgendaSourceVersion.self, args[3])
                }
                try output(receipt)
                return receipt.results.contains(where: { $0.status != "success" }) ? 3 : 0
            case "receipt":
                guard args.count == 3 else { throw AgendaWorkflowError.invalid("receipt requires batch ID and ledger directory") }
                let engine = AgendaWorkflowEngine(store: store, ledger: AgendaWorkflowLedger(root: URL(fileURLWithPath: args[2])))
                try output(engine.readReceipt(args[1]))
            default: throw AgendaWorkflowError.invalid("Unknown agenda command; no write attempted")
            }
            return 0
        } catch let failure as AgendaPrivacyFailure {
            // Preserve unknown separately, along with callback and actual status evidence.
            if let data = try? AgendaWorkflowCodec.data(failure.report) {
                FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
            }
            return 2
        } catch {
            let envelope = ["status": "blocked", "reason": String(describing: error), "completed": "not claimed",
                            "recovery": "For any execute failure, read the ledger before deciding; no blind retry"]
            if let data = try? AgendaWorkflowCodec.data(envelope) { FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8)) }
            return 2
        }
    }
}
