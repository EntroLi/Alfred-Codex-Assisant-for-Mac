import Foundation
import Testing
@testable import CodexQuotaBar

struct StabilityTests {
    @Test func activeClockPausesDuringIdleSleepAndPermissionDenial() {
        var clock = ActiveWorkClock()
        let start = Date(timeIntervalSince1970: 0)
        clock.resume(at: start)
        let triggered = clock.tick(at: start.addingTimeInterval(15), idleSeconds: 0, enabled: true, allowed: true, paused: false)
        #expect(!triggered)
        #expect(clock.accumulated == 15)
        _ = clock.tick(at: start.addingTimeInterval(30), idleSeconds: 600, enabled: true, allowed: true, paused: false)
        _ = clock.tick(at: start.addingTimeInterval(45), idleSeconds: 0, enabled: true, allowed: false, paused: false)
        _ = clock.tick(at: start.addingTimeInterval(60), idleSeconds: 0, enabled: true, allowed: true, paused: true)
        _ = clock.tick(at: start.addingTimeInterval(3600), idleSeconds: 0, enabled: true, allowed: true, paused: false)
        #expect(clock.accumulated == 15)
        clock.resume(at: start.addingTimeInterval(3600))
        _ = clock.tick(at: start.addingTimeInterval(3615), idleSeconds: 0, enabled: true, allowed: true, paused: false)
        #expect(clock.accumulated == 30)
    }
    @Test func thirtyActiveMinutesTriggersAndResets() {
        var clock = ActiveWorkClock()
        let start = Date(timeIntervalSince1970: 0)
        clock.resume(at: start)
        var triggers = 0
        for i in 1...120 {
            if clock.tick(at: start.addingTimeInterval(Double(i) * 15), idleSeconds: 0, enabled: true, allowed: true, paused: false) { triggers += 1 }
        }
        #expect(triggers == 1)
        #expect(clock.accumulated == 0)
    }
    @Test func onlyWeeklyAndMissingPercent() throws {
        let client = CodexRateLimitClient()
        let snapshot = try client.parse(rateLimits: ["secondary": ["usedPercent": 20, "windowDurationMins": 10080]])
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.weekly?.remainingPercent == 80)
        #expect(throws: (any Error).self) { try client.parse(rateLimits: ["secondary": ["windowDurationMins": 10080]]) }
    }
    @Test func officialCurrentWeightsAndUnknownRemainUnknown() {
        let tokens = TokenBreakdown(input: 1_000_000, cachedInput: 200_000, output: 100_000)
        #expect(CodexRateCard.cost(tokens: tokens, model: "gpt-6.1-sol") == 65.5)
        #expect(CodexRateCard.cost(tokens: tokens, model: "gpt-6-sol") == 66)
        #expect(CodexRateCard.cost(tokens: tokens, model: "future-model") == nil)
    }
    @Test func rpcTimeoutDoesNotBlockAndWeeklyRPCParses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = root.appendingPathComponent("mock-codex")
        let previous = ProcessInfo.processInfo.environment["CODEX_BINARY"]
        defer { if let previous { setenv("CODEX_BINARY", previous, 1) } else { unsetenv("CODEX_BINARY") } }
        try "#!/usr/bin/env python3\nimport time\ntime.sleep(20)\n".write(to: mock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.path)
        setenv("CODEX_BINARY", mock.path, 1)
        let started = Date()
        do { _ = try CodexRateLimitClient().readRateLimits(timeout: 0.25); Issue.record("Silent RPC should time out") } catch {}
        #expect(Date().timeIntervalSince(started) < 2)
        try """
        #!/usr/bin/env python3
        import sys, json
        for line in sys.stdin:
            msg = json.loads(line)
            if msg.get('id') == 1: print(json.dumps({'id':1,'result':{}}), flush=True)
            if msg.get('id') == 2:
                print(json.dumps({'id':2,'result':{'rateLimits':{'secondary':{'usedPercent':27,'windowDurationMins':10080}}}}), flush=True)
        """.write(to: mock, atomically: true, encoding: .utf8)
        let snapshot = try CodexRateLimitClient().readRateLimits(timeout: 2)
        #expect(snapshot.weekly?.remainingPercent == 73)
        #expect(snapshot.fiveHour == nil)
    }
    @Test func logStatesAndActualTitles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/10/03")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "12345678-1234-1234-1234-123456789abc"
        try "{\"id\":\"\(id)\",\"thread_name\":\"真正的标题\"}\n".write(to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let file = sessions.appendingPathComponent("rollout-\(id).jsonl")
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": id, "source": "cli"]]
        let started: [String: Any] = ["type": "event_msg", "payload": ["type": "task_started"]]
        func response(_ type: String, _ extra: [String: Any]) -> [String: Any] { ["type":"response_item","payload":extra.merging(["type":type]) { a,_ in a }] }
        func check(_ rows: [[String: Any]], _ kind: CodexActivityKind) throws {
            let text = try ([meta, started] + rows).map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            let activity = CodexStatusMonitor(codexHome: root).readActivity()
            #expect(activity.kind == kind)
            #expect(activity.sessionName == "真正的标题")
        }
        try check([], .thinking)
        try check([response("function_call", ["name":"functions.exec_command","call_id":"a","arguments":"{\"sandbox_permissions\":\"require_escalated\"}"])], .command)
        try check([response("function_call", ["name":"functions.request_user_input_async","call_id":"a","arguments":"{}"]), response("function_call_output", ["call_id":"a","output":"queued"])], .waitingQuestion)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 3600)], ofItemAtPath: file.path)
        let persistedWaiting = CodexStatusMonitor(codexHome: root).readActivity()
        #expect(persistedWaiting.kind == .waitingQuestion)
        #expect(persistedWaiting.sessionID == id)
        try check([["type":"turn_context","payload":["collaboration_mode":"plan"]], response("function_call", ["name":"update_plan","call_id":"a","arguments":"{}"]), ["type":"event_msg","payload":["type":"task_complete"]]], .waitingReview)
        try check([["type":"event_msg","payload":["type":"task_complete"]]], .idle)
    }
}
