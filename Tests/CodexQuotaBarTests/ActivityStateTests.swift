import AppKit
import Foundation
import Testing
@testable import CodexQuotaBar

struct ActivityStateTests {
    private let now = Date(timeIntervalSince1970: 1791045000)
    private func event(_ type: String) -> [String: Any] { ["type":"event_msg", "payload":["type":type]] }
    private func response(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        ["type":"response_item", "payload":fields.merging(["type":type]) { a,_ in a }]
    }
    @Test func completionAndLateQuotedOutputCannotReviveWork() {
        var state = ActivityLogState()
        state.consume(event("task_started"), fallbackDate: now)
        state.consume(response("function_call", ["call_id":"x", "name":"functions.exec_command"]), fallbackDate: now)
        #expect(state.kind(now: now) == .command)
        state.consume(response("function_call_output", ["call_id":"x", "output":"task_complete final_answer Plan mode require_escalated"]), fallbackDate: now)
        #expect(state.kind(now: now) == .thinking)
        state.consume(event("task_complete"), fallbackDate: now)
        state.consume(response("function_call_output", ["call_id":"old", "output":"task_started reasoning"]), fallbackDate: now.addingTimeInterval(60))
        #expect(state.kind(now: now.addingTimeInterval(60)) == .idle)
        #expect(state.updatedAt == now)
        #expect(state.completedAt == now)
    }
    @Test func questionSurvivesQueuedOutputAndFinalUntilUserReply() {
        var state = ActivityLogState()
        state.consume(event("task_started"), fallbackDate: now)
        state.consume(response("function_call", ["call_id":"q", "name":"functions.request_user_input_async"]), fallbackDate: now)
        state.consume(response("function_call_output", ["call_id":"q", "output":"{\"accepted\":true}"]), fallbackDate: now)
        state.consume(event("task_complete"), fallbackDate: now)
        #expect(state.kind(now: now.addingTimeInterval(8 * 3600)) == .waitingQuestion)
        state.consume(response("message", ["role":"user"]), fallbackDate: now.addingTimeInterval(8 * 3600))
        #expect(state.kind(now: now.addingTimeInterval(8 * 3600)) == .thinking)
    }
    @Test func modeAndPrivilegesRequireStructuredEvidence() {
        var state = ActivityLogState()
        state.consume(event("task_started"), fallbackDate: now)
        state.consume(response("function_call", ["name":"functions.exec", "call_id":"outer", "arguments":"Plan mode require_escalated request_user_input"]), fallbackDate: now)
        #expect(state.kind(now: now) == .tool)
        state.consume(["type":"turn_context","payload":["collaboration_mode":["mode":"plan"]]], fallbackDate: now)
        state.consume(response("function_call", ["name":"functions.update_plan", "call_id":"p"]), fallbackDate: now)
        #expect(state.kind(now: now) == .tool)
        state.consume(event("task_complete"), fallbackDate: now)
        #expect(state.kind(now: now) == .waitingReview)
        state.consume(event("turn_aborted"), fallbackDate: now)
        #expect(state.kind(now: now) == .idle)
        state.consume(event("approval_requested"), fallbackDate: now)
        #expect(state.kind(now: now) == .waitingApproval)
    }
    @Test func longUtf8LogAppendAndTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-12345678-1234-1234-1234-123456789abc.jsonl")
        func line(_ row: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self) + "\n" }
        let initial = try line(event("task_started")) + line(response("function_call", ["name":"functions.exec_command", "call_id":"a"]))
            + line(response("function_call_output", ["call_id":"a", "output":String(repeating:"装备用于作业，task_complete。", count:10000)]))
        try initial.write(to: file, atomically: true, encoding: .utf8)
        let monitor = CodexStatusMonitor(codexHome: root)
        #expect(monitor.readActivity().kind == .thinking)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(event("task_complete")).utf8)); try handle.close()
        #expect(monitor.readActivity().kind == .idle)
        #expect(monitor.readActivity().completedAt != nil)
        try line(event("task_started")).write(to: file, atomically: true, encoding: .utf8)
        #expect(monitor.readActivity().kind == .thinking)
    }
    @Test func cycleKeepsFiveDistinctCompletedThreadsAndSurvivesRefresh() {
        func item(_ index: Int, _ kind: CodexActivityKind = .idle) -> CodexActivitySnapshot {
            CodexActivitySnapshot(kind: kind, sessionName:"任务\(index)", updatedAt:now.addingTimeInterval(Double(-index)),
                sessionID:String(format:"12345678-1234-1234-1234-%012d", index), completedAt:kind == .idle ? now : nil)
        }
        let primary = item(0, .thinking)
        let history = (1...8).map { item($0) } + [item(1)]
        var cycle = RecentThreadCycle(); cycle.update(primary: primary, activities: history)
        #expect(cycle.candidates.count == 5)
        #expect(cycle.next(now: now)?.sessionID == primary.sessionID)
        cycle.update(primary: primary, activities: history)
        #expect(cycle.next(now: now.addingTimeInterval(6))?.sessionID == item(1).sessionID)
        #expect(cycle.displayed(primary: primary, now: now.addingTimeInterval(6)).sessionName?.contains("回看 2/5") == true)
        for i in 2...4 { #expect(cycle.next(now: now.addingTimeInterval(Double(i + 6)))?.sessionID == item(i).sessionID) }
        #expect(cycle.next(now: now.addingTimeInterval(12))?.sessionID == primary.sessionID)
        #expect(cycle.next(now: now.addingTimeInterval(100))?.sessionID == primary.sessionID)
    }
    @Test func panelPlacementFitsDesktopAndFullscreenMenuEdge() {
        let desktop = NSRect(x:0,y:0,width:1440,height:875), size = NSSize(width:460,height:560)
        for screen in [desktop, NSRect(x:-1920,y:0,width:1920,height:1080)] {
            let anchor = NSRect(x:screen.maxX-30,y:screen.maxY+5,width:30,height:24)
            let origin = AlfredPanelPresenter.origin(anchor:anchor,screen:screen,size:size)
            #expect(screen.contains(NSRect(origin:origin,size:size)))
        }
    }
}
