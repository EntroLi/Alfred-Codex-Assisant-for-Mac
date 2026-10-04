import Foundation
import Testing
@testable import CodexQuotaBar

struct ButlerNavigationTests {
    let now = Date(timeIntervalSince1970: 1791045000)
    let id = "12345678-1234-1234-1234-123456789abc"
    func line(_ route: String, _ window: Int = 1, date: Date? = nil) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(f.string(from: date ?? now)) info [electron-message-handler] IAB_LIFECYCLE received browser sidebar owner sync browserTabId=null conversationId=\(id) originWebContentsId=1 ownerRoutePath=\(route) windowId=\(window)\n"
    }
    @Test func existingDotNeverRenavigatesButOtherThreadDoes() {
        var gate = ButlerNavigationGate()
        let dot = CodexWindowRoute(path: "/dots/\(id)", observedAt: now)
        for _ in 0..<5 { #expect(gate.action(processID: 42, route: dot, now: now) == .focus) }
        let task = CodexWindowRoute(path: "/local/\(id)", observedAt: now.addingTimeInterval(1))
        #expect(gate.action(processID: 42, route: task, now: now.addingTimeInterval(1)) == .navigate)
        gate.didNavigateElsewhere(now: now.addingTimeInterval(2))
        #expect(gate.action(processID: 42, route: dot, now: now.addingTimeInterval(2)) == .navigate)
        #expect(gate.action(processID: 42, route: CodexWindowRoute(path: dot.path, observedAt: now.addingTimeInterval(3)), now: now.addingTimeInterval(3)) == .focus)
    }
    @Test func rapidTapDebouncesAcceptedRequestOnlyAndResetsAfterRestart() {
        var gate = ButlerNavigationGate()
        #expect(gate.action(processID: 42, route: nil, now: now) == .navigate)
        gate.didRequestNavigation(accepted: false, now: now)
        #expect(gate.action(processID: 42, route: nil, now: now) == .navigate)
        gate.didRequestNavigation(accepted: true, now: now)
        #expect(gate.action(processID: 42, route: nil, now: now.addingTimeInterval(1)) == .focus)
        #expect(gate.action(processID: 43, route: nil, now: now.addingTimeInterval(1)) == .navigate)
        #expect(gate.action(processID: 43, route: nil, now: now.addingTimeInterval(2)) == .navigate)
    }
    @Test func latestRouteWinsAndIncompleteOrQuotedRowsCannotReplaceIt() {
        let initial = line("/dots/\(id)")
        let partial = String(line("/local/\(id)", date: now.addingTimeInterval(1)).dropLast())
        #expect(CodexWindowRouteReader.observations(initial + partial, since: nil).routes["1"]?.isButlerConversation == true)
        let latest = CodexWindowRouteReader.observations(initial + partial + "\n", since: nil)
        #expect(latest.routes["1"]?.isButlerConversation == false)
        #expect(CodexWindowRouteReader.observations(initial, since: now.addingTimeInterval(1)).routes.isEmpty)
        #expect(CodexWindowRoute(path: "/dots/new", observedAt: now).isButlerConversation == false)
        #expect(CodexWindowRoute(path: "", observedAt: now).isButlerConversation == false)
        let quoted = line("/local/\(id)").replacingOccurrences(of: "info [electron-message-handler]", with: "info [quoted-tool-output] text=[electron-message-handler]")
        #expect(CodexWindowRouteReader.observations(initial + quoted, since: nil).routes["1"]?.isButlerConversation == true)
    }
    @Test func readerUsesCurrentProcessOnlyAndRejectsMultipleOrAuxiliaryWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; f.timeZone = TimeZone(secondsFromGMT: 0)
        let folder = root.appendingPathComponent(f.string(from: now)); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("codex-desktop-test-42-t0-i1-000000-0.log")
        try line("/dots/\(id)").write(to: file, atomically: true, encoding: .utf8)
        let reader = CodexWindowRouteReader(root: root)
        #expect(reader.read(processID: 42, launchedAt: now, now: now)?.isButlerConversation == true)
        #expect(reader.read(processID: 43, launchedAt: now, now: now) == nil)
        try (line("/dots/\(id)") + line("/local/\(id)", 2)).write(to: file, atomically: true, encoding: .utf8)
        #expect(reader.read(processID: 42, launchedAt: now, now: now) == nil)
        let ignored = "2026-10-03T12:30:00.000Z info [electron-message-handler] IAB_LIFECYCLE ignored browser sidebar owner sync from auxiliary window windowId=2\n"
        // Construct the ignored row at the same test date so launch filtering is exercised too.
        let prefix = String(line("/", date: now).prefix(24))
        try (line("/dots/\(id)") + line("/local/\(id)", 2) + prefix + ignored.dropFirst(24)).write(to: file, atomically: true, encoding: .utf8)
        #expect(reader.read(processID: 42, launchedAt: now, now: now)?.isButlerConversation == true)
    }
}
