import Testing
import Foundation
@testable import CodexQuotaBar

@Suite(.serialized)
final class UsageAnalyticsTests {
    private var root: URL!
    private var codexHome: URL!
    private var cacheURL: URL!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        codexHome = root.appendingPathComponent(".codex")
        cacheURL = root.appendingPathComponent("cache.json")
        try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("sessions/2026/07/23"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func testTokenDeltasTaskBoundaryAndLatestRename() async throws {
        let id = "11111111-1111-1111-1111-111111111111"
        try writeIndex([
            ["id": id, "thread_name": "旧名称"],
            ["id": id, "thread_name": "新名称"]
        ])
        let file = sessionFile("root")
        try write(lines: [
            meta(id: id),
            event("task_started", at: "2026-07-23T00:00:00.000Z", extra: ["turn_id": "turn-1"]),
            turn(model: "gpt-5.5"),
            token(input: 100, cached: 40, output: 10, cumulative: 110),
            token(input: 200, cached: 100, output: 20, cumulative: 330),
            event("task_complete", at: "2026-07-23T00:02:00.000Z"),
            event("task_started", at: "2026-07-23T00:03:00.000Z", extra: ["turn_id": "turn-2"]),
            token(input: 50, cached: 0, output: 5, cumulative: 385)
        ], to: file)

        let snapshot = await refresh(UsageAnalyticsService(codexHome: codexHome, cacheURL: cacheURL))
        #expect(snapshot.recentTasks.count == 2)
        #expect(snapshot.recentTasks.last?.title == "新名称")
        #expect(snapshot.allTime.tokens.input == 350)
        #expect(snapshot.allTime.tokens.output == 35)
        #expect(snapshot.recentTasks.first?.completedAt == nil)
    }

    @Test func testSubagentIsAttributedToParentConversation() async throws {
        let id = "22222222-2222-2222-2222-222222222222"
        try writeIndex([["id": id, "thread_name": "主对话"]])
        try write(lines: [
            meta(id: id),
            event("task_started", at: "2026-07-23T00:00:00.000Z", extra: ["turn_id": "root-turn"]),
            turn(model: "gpt-5.5"),
            token(input: 100, cached: 0, output: 10, cumulative: 110),
            event("task_complete", at: "2026-07-23T00:10:00.000Z")
        ], to: sessionFile("root"))
        try write(lines: [
            meta(id: "33333333-3333-3333-3333-333333333333", parent: id, subagent: true),
            event("task_started", at: "2026-07-23T00:02:00.000Z", extra: ["turn_id": "child-turn"]),
            turn(model: "codex-auto-review"),
            token(input: 30, cached: 10, output: 3, cumulative: 33),
            event("task_complete", at: "2026-07-23T00:03:00.000Z")
        ], to: sessionFile("child"))

        let snapshot = await refresh(UsageAnalyticsService(codexHome: codexHome, cacheURL: cacheURL))
        #expect(snapshot.recentTasks.count == 1)
        #expect(snapshot.recentTasks[0].tokens.total == 143)
        #expect(snapshot.recentTasks[0].estimatedPricing)
        #expect(snapshot.dailyBuckets.last?.topConversations.first?.title == "主对话")
    }

    @Test func testDailyHoverKeepsOnlyTopThreeConversations() async throws {
        var indexEntries: [[String: String]] = []
        for number in 1...4 {
            let suffix = String(repeating: "\(number)", count: 12)
            let id = "66666666-6666-6666-6666-\(suffix)"
            indexEntries.append(["id": id, "thread_name": "对话\(number)"])
            try write(lines: completeTask(id: id, turn: "turn-\(number)", input: number * 1_000), to: sessionFile("daily-\(number)"))
        }
        try writeIndex(indexEntries)

        let snapshot = await refresh(UsageAnalyticsService(codexHome: codexHome, cacheURL: cacheURL))
        let top = snapshot.dailyBuckets.last?.topConversations ?? []
        #expect(top.count == 3)
        #expect(top.first?.title == "对话4")
        #expect(top.last?.title == "对话2")
    }

    @Test func testUnknownModelAndQuotaCalibrationSurviveReset() async throws {
        let id = "44444444-4444-4444-4444-444444444444"
        try writeIndex([["id": id, "thread_name": "未知模型"]])
        let file = sessionFile("unknown")
        try write(lines: [
            meta(id: id),
            event("task_started", at: "2026-07-23T00:00:00.000Z", extra: ["turn_id": "turn-1"]),
            turn(model: "future-model"),
            token(input: 1_000, cached: 500, output: 100, cumulative: 1_100),
            event("task_complete", at: "2026-07-23T00:01:00.000Z")
        ], to: file)
        let service = UsageAnalyticsService(codexHome: codexHome, cacheURL: cacheURL)
        #expect(await refresh(service).containsEstimatedPricing)

        let resetA = Date().addingTimeInterval(4 * 24 * 60 * 60)
        let first = await record(service, LimitWindow(title: "周限额", usedPercent: 10, resetDate: resetA))
        #expect(first.weeklyCapacityCredits != nil)
        let resetB = resetA.addingTimeInterval(7 * 24 * 60 * 60)
        let afterReset = await record(service, LimitWindow(title: "周限额", usedPercent: 1, resetDate: resetB))
        #expect(afterReset.weeklyCapacityCredits ?? 0 > 0)
        #expect(afterReset.confidence == .low)
    }

    @Test func testTruncatedLogReplacesOldRecords() async throws {
        let id = "55555555-5555-5555-5555-555555555555"
        try writeIndex([["id": id, "thread_name": "截断测试"]])
        let file = sessionFile("truncate")
        try write(lines: completeTask(id: id, turn: "large", input: 9_000), to: file)
        let service = UsageAnalyticsService(codexHome: codexHome, cacheURL: cacheURL)
        #expect(await refresh(service).allTime.tokens.input == 9_000)

        try write(lines: completeTask(id: id, turn: "small", input: 90), to: file)
        #expect(await refresh(service).allTime.tokens.input == 90)
    }

    @Test func legacyCalibrationSamplesRemainIntactAcrossUpgrade() async throws {
        let reset = Date().addingTimeInterval(3600)
        let sampled = Date().timeIntervalSinceReferenceDate
        let old = (0..<500).map { number -> [String: Any] in
            ["sampledAt": sampled - Double(499 - number), "usedPercent": 5.0,
             "resetAt": reset.timeIntervalSinceReferenceDate, "localCreditsAtSample": 1.0]
        }
        let cache: [String: Any] = ["version": 2, "files": [:], "completedTasks": [], "quotaSamples": old]
        try JSONSerialization.data(withJSONObject: cache).write(to: cacheURL)
        let service = UsageAnalyticsService(codexHome: codexHome, cacheURL: cacheURL)
        _ = await record(service, LimitWindow(title: "周", usedPercent: 5, resetDate: reset))
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
        let samples = result["quotaSamples"] as! [[String: Any]]
        #expect(samples.count == 501)
        #expect(samples.filter { $0["rateCardVersion"] == nil }.count == 500)
        #expect(samples.last?["rateCardVersion"] as? String == CodexRateCard.version)
    }

    private func refresh(_ service: UsageAnalyticsService) async -> UsageAnalyticsSnapshot {
        await withCheckedContinuation { continuation in service.refresh { continuation.resume(returning: $0) } }
    }
    private func record(_ service: UsageAnalyticsService, _ window: LimitWindow) async -> UsageAnalyticsSnapshot {
        await withCheckedContinuation { continuation in service.recordWeeklyQuota(window) { continuation.resume(returning: $0) } }
    }

    private func sessionFile(_ name: String) -> URL {
        codexHome.appendingPathComponent("sessions/2026/07/23/rollout-\(name).jsonl")
    }

    private func writeIndex(_ entries: [[String: String]]) throws {
        let text = try entries.map { entry in
            String(data: try JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try text.write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
    }

    private func write(lines: [[String: Any]], to url: URL) throws {
        // Keep daily-hover fixtures in the current local day instead of expiring in July.
        let oldStart = ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z")!
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60)
        let adjusted = try lines.map { original -> String in
            var line = original
            if let stamp = line["timestamp"] as? String {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: stamp) { line["timestamp"] = formatter.string(from: start.addingTimeInterval(date.timeIntervalSince(oldStart))) }
            }
            return String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try adjusted.write(to: url, atomically: true, encoding: .utf8)
    }

    private func meta(id: String, parent: String? = nil, subagent: Bool = false) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "session_id": id, "thread_source": subagent ? "subagent" : "user"]
        if let parent { payload["parent_thread_id"] = parent }
        if subagent { payload["source"] = ["subagent": ["other": "guardian"]] }
        return ["timestamp": "2026-07-23T00:00:00.000Z", "type": "session_meta", "payload": payload]
    }

    private func turn(model: String) -> [String: Any] {
        ["timestamp": "2026-07-23T00:00:01.000Z", "type": "turn_context", "payload": ["model": model]]
    }

    private func event(_ type: String, at: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["timestamp": at, "type": "event_msg", "payload": extra.merging(["type": type]) { first, _ in first }]
    }

    private func token(input: Int, cached: Int, output: Int, cumulative: Int) -> [String: Any] {
        [
            "timestamp": "2026-07-23T00:00:30.000Z", "type": "event_msg",
            "payload": ["type": "token_count", "info": [
                "total_token_usage": ["total_tokens": cumulative],
                "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]
            ]]
        ]
    }

    private func completeTask(id: String, turn: String, input: Int) -> [[String: Any]] {
        [
            meta(id: id),
            event("task_started", at: "2026-07-23T00:00:00.000Z", extra: ["turn_id": turn]),
            self.turn(model: "gpt-5.5"),
            token(input: input, cached: 0, output: 1, cumulative: input + 1),
            event("task_complete", at: "2026-07-23T00:01:00.000Z")
        ]
    }
}
