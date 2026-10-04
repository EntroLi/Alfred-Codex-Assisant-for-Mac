import Foundation

struct TokenBreakdown: Codable, Equatable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var output: Int64 = 0

    var total: Int64 { input + output }

    static func + (left: TokenBreakdown, right: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: left.input + right.input,
            cachedInput: left.cachedInput + right.cachedInput,
            output: left.output + right.output
        )
    }

    static func += (left: inout TokenBreakdown, right: TokenBreakdown) {
        left = left + right
    }
}

struct TaskUsageRecord: Codable, Identifiable {
    var id: String
    var conversationID: String
    var title: String
    var model: String
    var startedAt: Date
    var completedAt: Date?
    var tokens: TokenBreakdown
    var isSubagent: Bool
    var sourcePath: String
    var estimatedPricing = false
}

struct DailyUsageBucket {
    let date: Date
    let tokens: TokenBreakdown
    let credits: Double
    let weeklyEquivalent: Double?
    let topConversations: [DailyConversationUsage]
}

struct DailyConversationUsage {
    let title: String
    let tokens: TokenBreakdown
    let weeklyEquivalent: Double?
}

struct UsageSummary {
    let tokens: TokenBreakdown
    let credits: Double
    let weeklyEquivalent: Double?
}

enum CalibrationConfidence: String, Codable {
    case unavailable = "待校准"
    case low = "低"
    case medium = "中"
    case high = "高"
}

struct QuotaCalibrationWindow: Codable {
    let sampledAt: Date
    let usedPercent: Double
    let resetAt: Date
    let localCreditsAtSample: Double
    var rateCardVersion: String? = nil
}

struct CalibrationQuality {
    var sampleCount = 0
    var usablePairs = 0
    var lastSample: Date?
    var relativeSpread: Double?
    var description: String {
        let formatter = DateFormatter(); formatter.dateFormat = "M/d HH:mm"
        let last = lastSample.map { formatter.string(from: $0) } ?? "暂无"
        let spread = relativeSpread.map { String(format: "样本离散度 %.0f%%", $0 * 100) } ?? "偏差待评估"
        return "样本 \(sampleCount) · 有效变化 \(usablePairs) · 最近 \(last)\n\(spread) · 含账户其他入口用量，当前只展示 token"
    }
    static func evaluate(samples: [QuotaCalibrationWindow]) -> CalibrationQuality {
        let ordered = samples.filter { $0.rateCardVersion == CodexRateCard.version }.sorted { $0.sampledAt < $1.sampledAt }
        var capacities: [Double] = []
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            let percent = right.usedPercent - left.usedPercent, credits = right.localCreditsAtSample - left.localCreditsAtSample
            if abs(left.resetAt.timeIntervalSince(right.resetAt)) < 2, percent > 0, credits > 0 {
                capacities.append(credits / percent * 100)
            }
        }
        let sorted = capacities.sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        let spread: Double? = median.flatMap { value in
            guard sorted.count >= 2, value > 0 else { return nil }
            let deviations = sorted.map { abs($0 - value) / value }.sorted()
            return deviations[deviations.count / 2]
        }
        return CalibrationQuality(sampleCount: ordered.count, usablePairs: capacities.count, lastSample: ordered.last?.sampledAt, relativeSpread: spread)
    }
}

struct UsageAnalyticsSnapshot {
    let generatedAt: Date
    let coverageStart: Date?
    let dailyBuckets: [DailyUsageBucket]
    let recentTasks: [TaskUsageRecord]
    let today: UsageSummary
    let last7Days: UsageSummary
    let last30Days: UsageSummary
    let allTime: UsageSummary
    let highestTask: TaskUsageRecord?
    let highestConversationTitle: String?
    let highestConversationCredits: Double
    let highestConversationTokens: TokenBreakdown
    let weeklyCapacityCredits: Double?
    let weeklyCapacityTokens: Double?
    let confidence: CalibrationConfidence
    let observedPercentagePoints: Double
    let rateCardVersion: String
    let containsEstimatedPricing: Bool
    var quality = CalibrationQuality()
    var highestConversationID: String? = nil
    var showWeeklyEstimates: Bool { confidence == .high && !containsEstimatedPricing && quality.usablePairs >= 5 && (quality.relativeSpread ?? 1) <= 0.35 }

    static let empty = UsageAnalyticsSnapshot(
        generatedAt: Date(), coverageStart: nil, dailyBuckets: [], recentTasks: [],
        today: UsageSummary(tokens: TokenBreakdown(), credits: 0, weeklyEquivalent: nil),
        last7Days: UsageSummary(tokens: TokenBreakdown(), credits: 0, weeklyEquivalent: nil),
        last30Days: UsageSummary(tokens: TokenBreakdown(), credits: 0, weeklyEquivalent: nil),
        allTime: UsageSummary(tokens: TokenBreakdown(), credits: 0, weeklyEquivalent: nil),
        highestTask: nil, highestConversationTitle: nil, highestConversationCredits: 0,
        highestConversationTokens: TokenBreakdown(),
        weeklyCapacityCredits: nil, weeklyCapacityTokens: nil, confidence: .unavailable,
        observedPercentagePoints: 0, rateCardVersion: CodexRateCard.version,
        containsEstimatedPricing: false
    )
}

private struct ModelRate {
    let input: Double
    let cachedInput: Double
    let output: Double
}

enum CodexRateCard {
    // Official Standard Codex credit weights, verified 2026-10-03.
    // Subscription consumption, speed tiers and shared usage can differ; never an exact quota.
    static let version = "2026-10-03-standard"
    static let source = "https://learn.chatgpt.com/docs/pricing#token-rates"
    private static let rates: [String: ModelRate] = [
        "gpt-6.1-sol": ModelRate(input: 50, cachedInput: 2.5, output: 250),
        "gpt-6-astra": ModelRate(input: 250, cachedInput: 25, output: 1250),
        "gpt-6-sol": ModelRate(input: 50, cachedInput: 5, output: 250),
        "gpt-6-luna": ModelRate(input: 2.5, cachedInput: 0.25, output: 12.5),
        "gpt-5.6-sol": ModelRate(input: 100, cachedInput: 10, output: 500),
        "gpt-5.6-terra": ModelRate(input: 50, cachedInput: 5, output: 300),
        "gpt-5.6-luna": ModelRate(input: 5, cachedInput: 0.5, output: 30),
        "gpt-5.5": ModelRate(input: 125, cachedInput: 12.5, output: 750)
    ]

    static func cost(tokens: TokenBreakdown, model: String) -> Double? {
        guard let rate = rates[model.lowercased()] else { return nil }
        let uncached = max(0, tokens.input - tokens.cachedInput)
        return Double(uncached) / 1_000_000 * rate.input
            + Double(tokens.cachedInput) / 1_000_000 * rate.cachedInput
            + Double(tokens.output) / 1_000_000 * rate.output
    }
}

private struct ActiveTaskState: Codable {
    var id: String
    var startedAt: Date
    var model: String
    var tokens: TokenBreakdown
}

private struct AnalyticsFileState: Codable {
    var offset: UInt64 = 0
    var fileSize: UInt64 = 0
    var sessionID = ""
    var conversationID = ""
    var currentModel = "unknown"
    var isSubagent = false
    var activeTask: ActiveTaskState?
}

private struct AnalyticsCache: Codable {
    var version = 2
    var files: [String: AnalyticsFileState] = [:]
    var completedTasks: [TaskUsageRecord] = []
    var quotaSamples: [QuotaCalibrationWindow] = []
}

final class UsageAnalyticsService {
    private let queue = DispatchQueue(label: "local.codex.quota.analytics", qos: .utility)
    private let fileManager: FileManager
    private let codexHome: URL
    private let sessionsRoot: URL
    private let sessionIndexURL: URL
    private let cacheURL: URL
    private var cache: AnalyticsCache
    private var latestSnapshot = UsageAnalyticsSnapshot.empty

    init(
        codexHome: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"),
        cacheURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.codexHome = codexHome
        self.sessionsRoot = codexHome.appendingPathComponent("sessions")
        self.sessionIndexURL = codexHome.appendingPathComponent("session_index.jsonl")
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexQuotaBar", isDirectory: true)
        let environmentCache = ProcessInfo.processInfo.environment["CODEX_QUOTA_ANALYTICS_CACHE"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        self.cacheURL = cacheURL ?? environmentCache ?? appSupport.appendingPathComponent("usage-analytics.json")
        self.cache = Self.loadCache(from: self.cacheURL) ?? AnalyticsCache()
        self.latestSnapshot = buildSnapshot(from: self.cache)
    }

    func cachedSnapshot() -> UsageAnalyticsSnapshot {
        queue.sync { latestSnapshot }
    }

    func refresh(completion: @escaping (UsageAnalyticsSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.scanChangedFiles()
            self.latestSnapshot = self.buildSnapshot(from: self.cache)
            self.saveCache()
            let snapshot = self.latestSnapshot
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func recordWeeklyQuota(_ window: LimitWindow, completion: ((UsageAnalyticsSnapshot) -> Void)? = nil) {
        guard let resetAt = window.resetDate else {
            if let completion { refresh(completion: completion) }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.scanChangedFiles()
            let windowStart = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
            let credits = self.costedRecords(from: self.mergedRecords(cache: self.cache))
                .filter { ($0.record.completedAt ?? $0.record.startedAt) >= windowStart }
                .reduce(0) { $0 + $1.credits }
            let sample = QuotaCalibrationWindow(
                sampledAt: Date(), usedPercent: window.usedPercent,
                resetAt: resetAt, localCreditsAtSample: credits, rateCardVersion: CodexRateCard.version
            )
            if let last = self.cache.quotaSamples.last,
               last.rateCardVersion == CodexRateCard.version,
               abs(last.sampledAt.timeIntervalSince(sample.sampledAt)) < 30,
               abs(last.usedPercent - sample.usedPercent) < 0.001,
               abs(last.resetAt.timeIntervalSince(sample.resetAt)) < 1 {
                self.cache.quotaSamples[self.cache.quotaSamples.count - 1] = sample
            } else {
                self.cache.quotaSamples.append(sample)
            }
            // Keep legacy calibration history intact; bound only samples of the current weight version.
            while self.cache.quotaSamples.filter({ $0.rateCardVersion == CodexRateCard.version }).count > 500 {
                guard let index = self.cache.quotaSamples.firstIndex(where: { $0.rateCardVersion == CodexRateCard.version }) else { break }
                self.cache.quotaSamples.remove(at: index)
            }
            self.latestSnapshot = self.buildSnapshot(from: self.cache)
            self.saveCache()
            let result = self.latestSnapshot
            if let completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func scanChangedFiles() {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var existing = Set<String>()
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let path = url.path
            existing.insert(path)
            let size = UInt64(values.fileSize ?? 0)
            var state = cache.files[path] ?? AnalyticsFileState()
            if size < state.offset || size < state.fileSize {
                cache.completedTasks.removeAll { $0.sourcePath == path }
                state = AnalyticsFileState()
            }
            guard size > state.offset else {
                state.fileSize = size
                cache.files[path] = state
                continue
            }
            scan(url: url, state: &state)
            state.fileSize = size
            cache.files[path] = state
        }

        let removed = Set(cache.files.keys).subtracting(existing)
        if !removed.isEmpty {
            cache.completedTasks.removeAll { removed.contains($0.sourcePath) }
            for path in removed { cache.files.removeValue(forKey: path) }
        }
    }

    private func scan(url: URL, state: inout AnalyticsFileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        var buffer = Data()
        var consumed: UInt64 = 0

        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                let line = buffer[lineStart..<newline]
                autoreleasepool {
                    parseLine(Data(line), path: url.path, state: &state)
                }
                consumed += UInt64(line.count + 1)
                lineStart = buffer.index(after: newline)
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }
        state.offset += consumed
    }

    private func parseLine(_ data: Data, path: String, state: inout AnalyticsFileState) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }
        let timestamp = Self.parseDate(object["timestamp"] as? String) ?? Date()

        switch type {
        case "session_meta":
            state.sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? state.sessionID
            let parent = payload["parent_thread_id"] as? String
            state.conversationID = parent ?? state.sessionID
            state.isSubagent = payload["thread_source"] as? String == "subagent"
                || (payload["source"] as? [String: Any])?["subagent"] != nil
        case "turn_context":
            if let model = payload["model"] as? String {
                state.currentModel = model
                state.activeTask?.model = model
            }
        case "event_msg":
            parseEvent(payload, timestamp: timestamp, path: path, state: &state)
        default:
            break
        }
    }

    private func parseEvent(_ payload: [String: Any], timestamp: Date, path: String, state: inout AnalyticsFileState) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "task_started":
            if let active = state.activeTask {
                append(active: active, completedAt: nil, path: path, state: state)
            }
            state.activeTask = ActiveTaskState(
                id: (payload["turn_id"] as? String) ?? UUID().uuidString,
                startedAt: timestamp, model: state.currentModel, tokens: TokenBreakdown()
            )
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any] else { return }
            if state.activeTask == nil {
                state.activeTask = ActiveTaskState(
                    id: "unscoped-\(Int(timestamp.timeIntervalSince1970))",
                    startedAt: timestamp, model: state.currentModel, tokens: TokenBreakdown()
                )
            }
            state.activeTask?.tokens += TokenBreakdown(
                input: Self.int64(usage["input_tokens"]),
                cachedInput: Self.int64(usage["cached_input_tokens"]),
                output: Self.int64(usage["output_tokens"])
            )
        case "task_complete", "turn_aborted":
            guard let active = state.activeTask else { return }
            append(active: active, completedAt: timestamp, path: path, state: state)
            state.activeTask = nil
        default:
            break
        }
    }

    private func append(active: ActiveTaskState, completedAt: Date?, path: String, state: AnalyticsFileState) {
        guard active.tokens.total > 0 else { return }
        cache.completedTasks.append(TaskUsageRecord(
            id: "\(state.sessionID):\(active.id)",
            conversationID: state.conversationID.isEmpty ? state.sessionID : state.conversationID,
            title: "", model: active.model, startedAt: active.startedAt,
            completedAt: completedAt, tokens: active.tokens,
            isSubagent: state.isSubagent, sourcePath: path
        ))
    }

    private func mergedRecords(cache: AnalyticsCache) -> [TaskUsageRecord] {
        var records = cache.completedTasks
        for (path, state) in cache.files {
            guard let active = state.activeTask, active.tokens.total > 0 else { continue }
            records.append(TaskUsageRecord(
                id: "\(state.sessionID):\(active.id)",
                conversationID: state.conversationID.isEmpty ? state.sessionID : state.conversationID,
                title: "", model: active.model, startedAt: active.startedAt,
                completedAt: nil, tokens: active.tokens, isSubagent: state.isSubagent,
                sourcePath: path
            ))
        }

        let names = readThreadNames()
        var roots = records.filter { !$0.isSubagent }
        let children = records.filter(\.isSubagent)
        for index in roots.indices {
            roots[index].title = names[roots[index].conversationID] ?? fallbackTitle(for: roots[index])
        }
        var unassigned: [TaskUsageRecord] = []
        for child in children {
            let childEnd = child.completedAt ?? child.startedAt
            let candidates = roots.indices.filter { index in
                roots[index].conversationID == child.conversationID
                    && roots[index].startedAt <= childEnd.addingTimeInterval(180)
                    && (roots[index].completedAt ?? Date()).addingTimeInterval(180) >= child.startedAt
            }
            if let target = candidates.min(by: { left, right in
                abs(roots[left].startedAt.timeIntervalSince(child.startedAt))
                    < abs(roots[right].startedAt.timeIntervalSince(child.startedAt))
            }) {
                roots[target].tokens += child.tokens
                roots[target].estimatedPricing = true
            } else {
                var orphan = child
                orphan.title = names[child.conversationID] ?? "其他内部开销"
                orphan.estimatedPricing = true
                unassigned.append(orphan)
            }
        }
        return roots + unassigned
    }

    private struct CostedRecord {
        var record: TaskUsageRecord
        let credits: Double
    }

    private func costedRecords(from records: [TaskUsageRecord]) -> [CostedRecord] {
        let known = records.compactMap { record -> (TaskUsageRecord, Double)? in
            guard let cost = CodexRateCard.cost(tokens: record.tokens, model: record.model) else { return nil }
            return (record, cost)
        }
        let knownTokens = known.reduce(Int64(0)) { $0 + $1.0.tokens.total }
        let fallbackPerToken = knownTokens > 0
            ? known.reduce(0.0) { $0 + $1.1 } / Double(knownTokens)
            : 0.000025

        return records.map { original in
            var record = original
            if let cost = CodexRateCard.cost(tokens: record.tokens, model: record.model) {
                return CostedRecord(record: record, credits: cost)
            }
            record.estimatedPricing = true
            return CostedRecord(record: record, credits: Double(record.tokens.total) * fallbackPerToken)
        }
    }

    private func buildSnapshot(from cache: AnalyticsCache) -> UsageAnalyticsSnapshot {
        let records = mergedRecords(cache: cache)
        let costed = costedRecords(from: records)
        guard !costed.isEmpty else { return .empty }
        let calibration = calibrationResult(samples: cache.quotaSamples)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let day30Start = calendar.date(byAdding: .day, value: -29, to: todayStart)!

        var buckets: [Date: (TokenBreakdown, Double)] = [:]
        var dailyConversations: [Date: [String: (String, TokenBreakdown, Double)]] = [:]
        for item in costed {
            let day = calendar.startOfDay(for: item.record.completedAt ?? item.record.startedAt)
            var value = buckets[day] ?? (TokenBreakdown(), 0)
            value.0 += item.record.tokens
            value.1 += item.credits
            buckets[day] = value

            var conversations = dailyConversations[day] ?? [:]
            var conversation = conversations[item.record.conversationID] ?? (item.record.title, TokenBreakdown(), 0)
            conversation.1 += item.record.tokens
            conversation.2 += item.credits
            conversations[item.record.conversationID] = conversation
            dailyConversations[day] = conversations
        }
        let daily = (0..<30).compactMap { offset -> DailyUsageBucket? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: day30Start) else { return nil }
            let value = buckets[date] ?? (TokenBreakdown(), 0)
            let topConversations = (dailyConversations[date] ?? [:]).values
                .sorted { $0.2 > $1.2 }
                .prefix(3)
                .map { conversation in
                    DailyConversationUsage(
                        title: conversation.0,
                        tokens: conversation.1,
                        weeklyEquivalent: calibration.capacity.map { conversation.2 / $0 }
                    )
                }
            return DailyUsageBucket(
                date: date, tokens: value.0, credits: value.1,
                weeklyEquivalent: calibration.capacity.map { value.1 / $0 },
                topConversations: topConversations
            )
        }

        func summary(since date: Date?) -> UsageSummary {
            let selected = costed.filter { item in
                guard let date else { return true }
                return (item.record.completedAt ?? item.record.startedAt) >= date
            }
            let tokens = selected.reduce(TokenBreakdown()) { $0 + $1.record.tokens }
            let credits = selected.reduce(0) { $0 + $1.credits }
            return UsageSummary(
                tokens: tokens, credits: credits,
                weeklyEquivalent: calibration.capacity.map { credits / $0 }
            )
        }

        let rootCosted = costed.filter { !$0.record.isSubagent || $0.record.title != "其他内部开销" }
        let highest = rootCosted.max { $0.credits < $1.credits }
        var conversations: [String: (String, Double, TokenBreakdown)] = [:]
        for item in costed {
            let current = conversations[item.record.conversationID] ?? (item.record.title, 0, TokenBreakdown())
            conversations[item.record.conversationID] = (
                current.0,
                current.1 + item.credits,
                current.2 + item.record.tokens
            )
        }
        let topConversation = conversations.values.max { $0.1 < $1.1 }
        let averageCreditPerToken = costed.reduce(0) { $0 + $1.credits }
            / Double(max(1, costed.reduce(Int64(0)) { $0 + $1.record.tokens.total }))

        return UsageAnalyticsSnapshot(
            generatedAt: Date(),
            coverageStart: records.map(\.startedAt).min(),
            dailyBuckets: daily,
            recentTasks: rootCosted.sorted {
                ($0.record.completedAt ?? $0.record.startedAt) > ($1.record.completedAt ?? $1.record.startedAt)
            }.prefix(8).map(\.record),
            today: summary(since: todayStart),
            last7Days: summary(since: calendar.date(byAdding: .day, value: -6, to: todayStart)),
            last30Days: summary(since: day30Start),
            allTime: summary(since: nil),
            highestTask: highest?.record,
            highestConversationTitle: topConversation?.0,
            highestConversationCredits: topConversation?.1 ?? 0,
            highestConversationTokens: topConversation?.2 ?? TokenBreakdown(),
            weeklyCapacityCredits: calibration.capacity,
            weeklyCapacityTokens: calibration.capacity.map { $0 / max(averageCreditPerToken, 0.0000001) },
            confidence: calibration.capacity == nil ? .unavailable : .low,
            observedPercentagePoints: calibration.observedPoints,
            rateCardVersion: CodexRateCard.version,
            containsEstimatedPricing: costed.contains { $0.record.estimatedPricing },
            quality: CalibrationQuality.evaluate(samples: cache.quotaSamples),
            highestConversationID: conversations.max { $0.value.1 < $1.value.1 }?.key
        )
    }

    private func calibrationResult(
        samples: [QuotaCalibrationWindow]
    ) -> (capacity: Double?, confidence: CalibrationConfidence, observedPoints: Double) {
        let ordered = samples.filter { $0.rateCardVersion == CodexRateCard.version }.sorted { $0.sampledAt < $1.sampledAt }
        var creditDelta = 0.0
        var percentDelta = 0.0
        var resetWindows = Set<Int64>()
        for pair in zip(ordered, ordered.dropFirst()) {
            let left = pair.0
            let right = pair.1
            guard abs(left.resetAt.timeIntervalSince(right.resetAt)) < 2 else { continue }
            let percent = right.usedPercent - left.usedPercent
            let credits = right.localCreditsAtSample - left.localCreditsAtSample
            guard percent > 0, credits > 0 else { continue }
            percentDelta += percent
            creditDelta += credits
            resetWindows.insert(Int64(right.resetAt.timeIntervalSince1970))
        }
        if percentDelta > 0 {
            let capacity = creditDelta / percentDelta * 100
            let confidence: CalibrationConfidence
            if resetWindows.count >= 2 && percentDelta >= 20 {
                confidence = .high
            } else if percentDelta >= 5 {
                confidence = .medium
            } else {
                confidence = .low
            }
            return (capacity, confidence, percentDelta)
        }

        for sample in ordered.reversed() where sample.usedPercent > 0 {
            let credits = sample.localCreditsAtSample
            if credits > 0 {
                return (credits / sample.usedPercent * 100, .low, sample.usedPercent)
            }
        }
        return (nil, .unavailable, 0)
    }

    private func readThreadNames() -> [String: String] {
        guard let data = try? Data(contentsOf: sessionIndexURL),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String,
                  !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }

    private func fallbackTitle(for record: TaskUsageRecord) -> String {
        let folder = URL(fileURLWithPath: record.sourcePath).deletingLastPathComponent().lastPathComponent
        return folder.isEmpty ? "未命名对话" : "Codex · \(folder)"
    }

    private func saveCache() {
        do {
            try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Statistics remain available in memory when persistence is unavailable.
        }
    }

    private static func loadCache(from url: URL) -> AnalyticsCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(AnalyticsCache.self, from: data),
              cache.version == 2 else { return nil }
        return cache
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }
}
