import AppKit
import Foundation
import Darwin
import UserNotifications

private func resolveCodexBinary(fileManager: FileManager = .default) -> URL? {
    var candidatePaths: [String] = []

    if let override = ProcessInfo.processInfo.environment["CODEX_BINARY"], !override.isEmpty {
        candidatePaths.append((override as NSString).expandingTildeInPath)
    }

    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
        candidatePaths.append(appURL.appendingPathComponent("Contents/Resources/codex").path)
    }

    candidatePaths.append(contentsOf: [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "~/Applications/ChatGPT.app/Contents/Resources/codex",
        "~/Applications/Codex.app/Contents/Resources/codex",
        "~/.local/bin/codex"
    ].map { ($0 as NSString).expandingTildeInPath })

    var seen = Set<String>()
    for path in candidatePaths where seen.insert(path).inserted {
        if fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
    }
    return nil
}

struct LimitWindow {
    let title: String
    let usedPercent: Double
    let resetDate: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaSnapshot {
    let fiveHour: LimitWindow?
    let weekly: LimitWindow?
    let fetchedAt: Date
}

enum CodexActivityKind: Int {
    case idle = 0
    case thinking = 10
    case tool = 20
    case editing = 30
    case command = 40
    case waitingQuestion = 90
    case waitingReview = 95
    case waitingApproval = 100

    var label: String {
        switch self {
        case .idle:
            return "🦇 蝙蝠洞待命"
        case .thinking:
            return "🦇 战术推演"
        case .command:
            return "⚙️ 任务执行"
        case .editing:
            return "🛠️ 装备改装"
        case .tool:
            return "🦇 装备调度"
        case .waitingQuestion:
            return "🦇 蝙蝠信号 · 待答复"
        case .waitingReview:
            return "🦇 战术方案 · 待审阅"
        case .waitingApproval:
            return "🦇 行动许可 · 待放行"
        }
    }

    var priority: Int {
        rawValue
    }
}

struct CodexActivitySnapshot {
    let kind: CodexActivityKind
    let sessionName: String?
    let updatedAt: Date
    var sessionID: String? = nil
    var completedAt: Date? = nil

    static let idle = CodexActivitySnapshot(kind: .idle, sessionName: nil, updatedAt: Date())

    var displayText: String {
        guard let sessionName, !sessionName.isEmpty else {
            return kind.label
        }
        return "\(kind.label) · \(sessionName)"
    }
}

func quotaColor(for percent: Double) -> NSColor {
    let level = quotaLevel(for: percent)
    let colors: [(CGFloat, CGFloat, CGFloat)] = [
        (0.92, 0.08, 0.08),
        (0.96, 0.18, 0.08),
        (0.98, 0.30, 0.06),
        (1.00, 0.45, 0.04),
        (1.00, 0.62, 0.04),
        (0.96, 0.78, 0.06),
        (0.78, 0.82, 0.08),
        (0.54, 0.78, 0.12),
        (0.32, 0.72, 0.18),
        (0.16, 0.64, 0.24),
        (0.02, 0.56, 0.30)
    ]
    let color = colors[max(0, min(10, level))]
    return NSColor(calibratedRed: color.0, green: color.1, blue: color.2, alpha: 1)
}

func quotaLevel(for percent: Double) -> Int {
    let clamped = max(0, min(100, percent))
    return max(0, min(10, Int((clamped / 10).rounded())))
}

private func panelPrimaryTextColor() -> NSColor {
    NSColor(calibratedWhite: 0.02, alpha: 1)
}

private func panelSecondaryTextColor() -> NSColor {
    NSColor(calibratedWhite: 0.02, alpha: 1)
}

final class CodexStatusMonitor {
    private let sessionsRoot: URL
    private let sessionIndexURL: URL
    private let fileManager = FileManager.default
    private let stateLock = NSLock()
    private struct CachedLog {
        var state = ActivityLogState()
        var offset: UInt64 = 0
        var pending = Data()
        var inode: UInt64 = 0
        var modifiedAt = Date.distantPast
    }
    private var logs: [String: CachedLog] = [:]

    init(codexHome: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")) {
        self.sessionsRoot = codexHome.appendingPathComponent("sessions")
        self.sessionIndexURL = codexHome.appendingPathComponent("session_index.jsonl")
    }

    func readActivity() -> CodexActivitySnapshot {
        readActivities().max { left, right in
            left.kind.priority == right.kind.priority ? left.updatedAt < right.updatedAt : left.kind.priority < right.kind.priority
        } ?? .idle
    }

    func readActivities() -> [CodexActivitySnapshot] {
        stateLock.lock(); defer { stateLock.unlock() }
        let now = Date()
        let threadNames = readThreadNames()
        let files = recentSessionFiles(since: now.addingTimeInterval(-48 * 60 * 60))
        var activities: [CodexActivitySnapshot] = []

        for file in files {
            guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                  let modifiedAt = attrs[.modificationDate] as? Date else {
                continue
            }

            let head = readHead(file, maxBytes: 32_000)
            if isSubagentSession(head) {
                continue
            }

            let tail = readTail(file, maxBytes: 220_000)
            let state = readState(file, attributes: attrs, modifiedAt: modifiedAt)
            guard state.updatedAt != nil else { continue }
            let kind = state.kind(now: now)
            activities.append(CodexActivitySnapshot(
                kind: kind,
                sessionName: displayName(for: file, metadata: head + "\n" + tail, threadNames: threadNames),
                updatedAt: state.updatedAt ?? modifiedAt,
                sessionID: sessionID(from: file),
                completedAt: state.active == false ? state.completedAt : nil
            ))
        }

        let paths = Set(files.map(\.path)); logs = logs.filter { paths.contains($0.key) }
        return activities
    }

    private func recentSessionFiles(since cutoff: Date) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff else {
                continue
            }
            urls.append(url)
        }

        return urls.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
    }

    private func readThreadNames() -> [String: String] {
        guard let data = try? Data(contentsOf: sessionIndexURL),
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let threadName = object["thread_name"] as? String,
                  !threadName.isEmpty else {
                continue
            }
            names[id] = threadName
        }
        return names
    }

    private func displayName(for file: URL, metadata: String, threadNames: [String: String]) -> String? {
        let ids = sessionIDs(for: file, metadata: metadata)
        for id in ids {
            if let threadName = threadNames[id] {
                return threadName
            }
        }
        return inferSessionName(from: metadata)
    }

    private func sessionIDs(for file: URL, metadata: String) -> [String] {
        var ids: [String] = []

        for line in metadata.split(separator: "\n").prefix(30) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            for key in ["id", "forked_from_id"] {
                guard let id = payload[key] as? String,
                      !ids.contains(id) else {
                    continue
                }
                ids.append(id)
            }
        }
        if let id = sessionID(from: file), !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private func isSubagentSession(_ metadata: String) -> Bool {
        for line in metadata.split(separator: "\n").prefix(8) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            if payload["thread_source"] as? String == "subagent" {
                return true
            }
            if let source = payload["source"] as? [String: Any],
               source["subagent"] != nil {
                return true
            }
        }
        return false
    }

    private func sessionID(from file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        let pattern = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return String(name[range])
    }

    private func readTail(_ url: URL, maxBytes: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func readHead(_ url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: maxBytes)
        return String(decoding: data, as: UTF8.self)
    }

    private func readState(_ file: URL, attributes: [FileAttributeKey: Any], modifiedAt: Date) -> ActivityLogState {
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var cached = logs[file.path] ?? CachedLog()
        if cached.inode != inode || size < cached.offset || (size == cached.offset && cached.modifiedAt != modifiedAt) {
            cached = CachedLog()
        }
        if cached.offset == size && cached.modifiedAt == modifiedAt { return cached.state }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return cached.state }
        defer { try? handle.close() }
        let maximum = 8 * 1024 * 1024
        var discardFirst = false
        if cached.offset == 0 && size > UInt64(maximum) {
            cached.offset = size - UInt64(maximum); discardFirst = true
        }
        try? handle.seek(toOffset: cached.offset)
        while let chunk = try? handle.read(upToCount: maximum), !chunk.isEmpty {
            cached.offset += UInt64(chunk.count)
            cached.pending.append(chunk)
            let rows = cached.pending.split(separator: 10, omittingEmptySubsequences: false)
            for (index, row) in rows.dropLast().enumerated() {
                if discardFirst && index == 0 { discardFirst = false; continue }
                if let object = try? JSONSerialization.jsonObject(with: Data(row)) as? [String: Any] {
                    cached.state.consume(object, fallbackDate: modifiedAt)
                }
            }
            cached.pending = Data(rows.last ?? Data.SubSequence())
            if cached.pending.count > maximum { cached.pending.removeAll(); discardFirst = true }
        }
        cached.inode = inode; cached.modifiedAt = modifiedAt
        logs[file.path] = cached
        return cached.state
    }

    private func inferSessionName(from tail: String) -> String? {
        let lines = tail.split(separator: "\n").prefix(20)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            if let name = payload["name"] as? String {
                return name
            }
        }

        return nil
    }

    private func containsAny<S: StringProtocol>(_ text: S, _ needles: [String]) -> Bool {
        needles.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

enum QuotaError: Error, LocalizedError {
    case codexMissing
    case launchFailed(String)
    case noRateLimits
    case timeout
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .codexMissing:
            return "找不到 Codex 可执行文件"
        case .launchFailed(let detail):
            return "启动 app-server 失败：\(detail)"
        case .noRateLimits:
            return "未读取到额度数据"
        case .timeout:
            return "读取额度超时"
        case .rpc(let message):
            return message
        }
    }
}

final class CodexRateLimitClient {
    func readRateLimits(timeout: TimeInterval = 12) throws -> QuotaSnapshot {
        guard let codexBinary = resolveCodexBinary() else {
            throw QuotaError.codexMissing
        }

        let process = Process()
        process.executableURL = codexBinary
        process.arguments = ["app-server", "--listen", "stdio://"]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw QuotaError.launchFailed(error.localizedDescription)
        }

        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning {
                        process.interrupt()
                    }
                }
            }
        }

        try sendJSON(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "SuiAssistant", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"],
            "capabilities": [:]
        ]], to: input.fileHandleForWriting)

        _ = try readJSONLine(from: output.fileHandleForReading, timeout: timeout)

        try sendJSON(["jsonrpc": "2.0", "method": "initialized", "params": [:]], to: input.fileHandleForWriting)
        try sendJSON(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]], to: input.fileHandleForWriting)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try readJSONLine(from: output.fileHandleForReading, timeout: max(0.2, deadline.timeIntervalSinceNow))
            if let id = message["id"] as? Int, id == 2 {
                if let error = message["error"] as? [String: Any] {
                    throw QuotaError.rpc(error["message"] as? String ?? "JSON-RPC 请求失败")
                }
                guard let result = message["result"] as? [String: Any],
                      let rateLimits = result["rateLimits"] as? [String: Any] else {
                    throw QuotaError.noRateLimits
                }
                return try parse(rateLimits: rateLimits)
            }
        }

        throw QuotaError.timeout
    }

    func parse(rateLimits: [String: Any]) throws -> QuotaSnapshot {
        let rawCandidates: [([String: Any]?, LimitWindowType)] = [
            (rateLimits["primary"] as? [String: Any], .fiveHour),
            (rateLimits["secondary"] as? [String: Any], .weekly)
        ]
        let candidates: [([String: Any], LimitWindowType)] = rawCandidates.compactMap { entry in
            guard let dictionary = entry.0 else { return nil }
            return (dictionary, entry.1)
        }

        var fiveHour: LimitWindow?
        var weekly: LimitWindow?

        for (dictionary, fallbackType) in candidates {
            let type = windowType(dictionary: dictionary) ?? fallbackType
            switch type {
            case .fiveHour:
                fiveHour = try parseWindow(title: "5小时", dictionary: dictionary)
            case .weekly:
                weekly = try parseWindow(title: "周限额", dictionary: dictionary)
            }
        }

        guard fiveHour != nil || weekly != nil else {
            throw QuotaError.noRateLimits
        }

        return QuotaSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: Date()
        )
    }

    private enum LimitWindowType {
        case fiveHour
        case weekly
    }

    private func windowType(dictionary: [String: Any]) -> LimitWindowType? {
        let durationMinutes = number(dictionary["windowDurationMins"])
            ?? number(dictionary["windowDurationMinutes"])
            ?? number(dictionary["windowMins"])

        guard let durationMinutes else { return nil }
        return durationMinutes >= 24 * 60 ? .weekly : .fiveHour
    }

    private func parseWindow(title: String, dictionary: [String: Any]) throws -> LimitWindow {
        guard let used = number(dictionary["usedPercent"]), used.isFinite, (0...100).contains(used) else { throw QuotaError.noRateLimits }
        let resetSeconds = number(dictionary["resetsAt"])
            ?? number(dictionary["resetAt"])
            ?? number(dictionary["resetTime"])

        let resetDate = resetSeconds.map { Date(timeIntervalSince1970: $0) }
        return LimitWindow(title: title, usedPercent: used, resetDate: resetDate)
    }

    private func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func sendJSON(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private func readJSONLine(from handle: FileHandle, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()

        while Date() < deadline {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, min(100, deadline.timeIntervalSinceNow * 1000))))
            if ready < 0 { if errno == EINTR { continue }; throw QuotaError.rpc("读取额度管道失败") }
            if ready == 0 { continue }
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                throw QuotaError.rpc("额度服务已关闭管道")
            }
            if byte.first == 0x0A {
                guard !data.isEmpty else { continue }
                let object = try JSONSerialization.jsonObject(with: data, options: [])
                return object as? [String: Any] ?? [:]
            }
            data.append(byte)
            if data.count > 4 * 1024 * 1024 { throw QuotaError.rpc("额度服务响应过大") }
        }

        throw QuotaError.timeout
    }
}

final class SegmentedBatteryView: NSView {
    var percent: Double = 0 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 168, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let segmentCount = 10
        let gap: CGFloat = 2
        let segmentWidth = (bounds.width - CGFloat(segmentCount - 1) * gap) / CGFloat(segmentCount)
        let filled = quotaLevel(for: percent)

        let activeColor = quotaColor(for: percent)

        for index in 0..<segmentCount {
            let rect = NSRect(
                x: CGFloat(index) * (segmentWidth + gap),
                y: 1,
                width: segmentWidth,
                height: bounds.height - 2
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            if index < filled {
                activeColor.setFill()
            } else {
                NSColor.separatorColor.withAlphaComponent(0.35).setFill()
            }
            path.fill()
        }
    }
}

final class QuotaRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let battery = SegmentedBatteryView()
    private let detailLabel = NSTextField(labelWithString: "--")

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = panelPrimaryTextColor()
        titleLabel.alignment = .left

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = panelSecondaryTextColor()
        detailLabel.alignment = .right
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(battery)
        addSubview(detailLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        battery.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 52),

            battery.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            battery.centerYAnchor.constraint(equalTo: centerYAnchor),
            battery.heightAnchor.constraint(equalToConstant: 16),

            detailLabel.leadingAnchor.constraint(equalTo: battery.trailingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant: 94)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with window: LimitWindow) {
        battery.percent = window.remainingPercent
        detailLabel.stringValue = "\(Int(window.remainingPercent.rounded()))% \(Self.format(date: window.resetDate))"
    }

    static func format(date: Date?) -> String {
        guard let date else { return "--:--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}

final class TouchBarQuotaView: NSView {
    private var snapshot: QuotaSnapshot?
    private var activity = CodexActivitySnapshot.idle
    private var activityRect = NSRect.zero
    var onStatusClick: (() -> Void)?
    var hasUnread = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); appearance = NSAppearance(named: .darkAqua) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 720, height: 30)
    }

    func update(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
    }

    func update(activity: CodexActivitySnapshot) {
        self.activity = activity
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawBrand()
        let quotaX: CGFloat = 104
        let quotaWidth: CGFloat = 252
        let activityX = quotaX + quotaWidth + 8

        if let weekly = snapshot?.weekly {
            drawQuotaRow(title: "周", window: weekly,
                rect: NSRect(x: quotaX, y: 9, width: quotaWidth, height: 11))
        } else {
            drawQuotaPlaceholder(in: NSRect(x: quotaX, y: 9, width: quotaWidth, height: 12))
        }

        activityRect = NSRect(
            x: activityX,
            y: 3,
            width: max(0, bounds.width - activityX - 8),
            height: 24
        )
        drawActivity(
            in: NSRect(
                x: activityX,
                y: 7,
                width: max(0, bounds.width - activityX - 8),
                height: 16
            )
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if activityRect.contains(point) {
            onStatusClick?()
        }
    }

    private func drawBrand() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AlfredTheme.font(ofSize: 12, weight: .bold),
            .foregroundColor: AlfredTheme.gold
        ]
        (hasUnread ? NSColor.systemOrange : NSColor.systemGray).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 13, width: 5, height: 5)).fill()
        AlfredTheme.bat(size: NSSize(width: 22, height: 14)).draw(in: NSRect(x: 10, y: 8, width: 22, height: 14))
        "Alfred".draw(
            in: NSRect(x: 32, y: 7, width: 68, height: 16),
            withAttributes: attributes
        )
    }

    private func drawActivity(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AlfredTheme.font(ofSize: 12, weight: .semibold),
            .foregroundColor: AlfredTheme.ink,
            .paragraphStyle: paragraph
        ]
        activity.displayText.draw(
            in: rect,
            withAttributes: attributes
        )
    }

    private func drawQuotaPlaceholder(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AlfredTheme.font(ofSize: 9, weight: .medium),
            .foregroundColor: AlfredTheme.muted
        ]
        "额度读取中...".draw(
            in: NSRect(x: rect.minX, y: 9, width: rect.width, height: 12),
            withAttributes: attributes
        )
    }

    private func drawQuotaRow(title: String, window: LimitWindow, rect: NSRect) {
        let percent = window.remainingPercent
        let labelWidth: CGFloat = 22
        let percentWidth: CGFloat = 38
        let timeWidth: CGFloat = 58
        let gap: CGFloat = 6
        let barX = rect.minX + labelWidth + gap
        let barWidth = max(0, rect.width - labelWidth - percentWidth - timeWidth - gap * 3)

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: AlfredTheme.font(ofSize: 10, weight: .medium),
            .foregroundColor: AlfredTheme.muted
        ]
        title.draw(
            in: NSRect(x: rect.minX, y: rect.minY, width: labelWidth, height: 14),
            withAttributes: textAttributes
        )

        drawSegments(
            in: NSRect(x: barX, y: rect.minY + 1, width: barWidth, height: 7),
            percent: percent
        )

        let percentParagraph = NSMutableParagraphStyle()
        percentParagraph.alignment = .left
        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: AlfredTheme.font(ofSize: 10, weight: .medium),
            .foregroundColor: AlfredTheme.muted,
            .paragraphStyle: percentParagraph
        ]
        "\(Int(percent.rounded()))%".draw(
            in: NSRect(x: barX + barWidth + gap, y: rect.minY, width: percentWidth, height: 14),
            withAttributes: percentAttributes
        )

        let timeParagraph = NSMutableParagraphStyle()
        timeParagraph.alignment = .right
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: AlfredTheme.font(ofSize: 10, weight: .medium),
            .foregroundColor: AlfredTheme.muted,
            .paragraphStyle: timeParagraph
        ]
        let formatter = DateFormatter(); formatter.dateFormat = "M/d"
        let reset = window.resetDate.map { formatter.string(from: $0) } ?? "--"
        reset.draw(
            in: NSRect(x: barX + barWidth + gap + percentWidth + gap, y: rect.minY, width: timeWidth, height: 14),
            withAttributes: timeAttributes
        )
    }

    private func drawSegments(in rect: NSRect, percent: Double) {
        let count = 10
        let gap: CGFloat = 1.5
        let segmentWidth = (rect.width - CGFloat(count - 1) * gap) / CGFloat(count)
        let filled = quotaLevel(for: percent)

        let activeColor = percent < 20 ? NSColor.systemRed : AlfredTheme.gold

        for index in 0..<count {
            let segmentRect = NSRect(
                x: rect.minX + CGFloat(index) * (segmentWidth + gap),
                y: rect.minY,
                width: segmentWidth,
                height: rect.height
            )
            let path = NSBezierPath(roundedRect: segmentRect, xRadius: 1.5, yRadius: 1.5)
            if index < filled {
                activeColor.setFill()
            } else {
                NSColor.separatorColor.withAlphaComponent(0.35).setFill()
            }
            path.fill()
        }
    }
}

final class TouchBarPresenter: NSObject, NSTouchBarDelegate {
    private let quotaView = TouchBarQuotaView(frame: NSRect(x: 0, y: 0, width: 720, height: 30))
    private let touchBar = NSTouchBar()
    private let itemIdentifier = NSTouchBarItem.Identifier("codex.quota.item")
    private let trayIdentifier = "codex.quota.touchbar"
    var onClose: (() -> Void)?
    var onStatusClick: (() -> Void)?
    var onButlerClick: (() -> Void)?
    var onQuotaClick: (() -> Void)?
    func updateUnread(_ unread: Bool) { quotaView.hasUnread = unread }

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [itemIdentifier]
        quotaView.onStatusClick = { [weak self] in
            self?.onStatusClick?()
        }
    }

    func update(snapshot: QuotaSnapshot) {
        quotaView.update(snapshot: snapshot)
    }

    func update(activity: CodexActivitySnapshot) {
        quotaView.update(activity: activity)
    }

    func presentSystemModal() {
        present()
    }

    func forcePresentSystemModal() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.present()
        }
    }

    func dismissSystemModal() {
        dismiss()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == itemIdentifier else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = makeContainer()
        return item
    }

    private func makeCloseButton() -> NSView {
        let button = NSButton(title: "×", target: self, action: #selector(closeTapped))
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 16, weight: .bold)
        button.setButtonType(.momentaryPushIn)
        button.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        return button
    }

    func makeContainer() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 756, height: 30))
        let closeButton = makeCloseButton()
        let statusButton = makeStatusButton()
        closeButton.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        quotaView.frame = NSRect(x: 36, y: 0, width: 720, height: 30)
        statusButton.frame = NSRect(x: 400, y: 0, width: 356, height: 30)
        container.addSubview(closeButton)
        container.addSubview(quotaView)
        container.addSubview(statusButton)
        let butlerTarget = makeTouchButton(action: #selector(butlerTapped), label: "打开 Your dot")
        butlerTarget.frame = NSRect(x: 36, y: 0, width: 100, height: 30)
        container.addSubview(butlerTarget)
        let quotaTarget = makeTouchButton(action: #selector(quotaTapped), label: "打开 Alfred 概览并刷新")
        quotaTarget.frame = NSRect(x: 140, y: 0, width: 252, height: 30)
        container.addSubview(quotaTarget)
        return container
    }

    private func makeTouchButton(action: Selector, label: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false; button.isTransparent = true
        button.setButtonType(.momentaryPushIn)
        button.toolTip = label; button.setAccessibilityLabel(label)
        return button
    }

    private func makeStatusButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(statusTapped))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.isTransparent = true
        button.frame = NSRect(x: 0, y: 0, width: 356, height: 30)
        button.toolTip = "回到 Codex"
        return button
    }

    private func present() {
        let selector = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        guard NSTouchBar.responds(to: selector) else { return }
        _ = NSTouchBar.perform(selector, with: touchBar, with: trayIdentifier)
    }

    private func dismiss() {
        let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
        guard NSTouchBar.responds(to: selector) else { return }
        _ = NSTouchBar.perform(selector, with: touchBar)
    }

    @objc private func closeTapped() {
        dismiss()
        onClose?()
    }

    @objc private func statusTapped() {
        onStatusClick?()
    }
    @objc private func butlerTapped() { onButlerClick?() }
    @objc private func quotaTapped() { onQuotaClick?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = CodexRateLimitClient()
    private let statusMonitor = CodexStatusMonitor()
    private let windowRouteReader = CodexWindowRouteReader()
    private var butlerNavigationGate = ButlerNavigationGate()
    private var lastButlerAction = "none"
    private let analyticsService = UsageAnalyticsService()
    private let workBreakReminder = WorkBreakReminder()
    private let inbox = AssistantInbox()
    private let agendaService = MacAgendaService()
    private lazy var desktopSticker = DesktopStickerController()
    private var assistantNotificationError: String?
    private var agendaText = "日历与提醒事项尚未连接"
    private var butlerStatus = "Alfred 本机服务在线 · Your dot 入口已连接\n语音请点管家页面的电话按钮。"
    private var currentBrief = ""
    private var currentTodos = ""
    private var latestActivities: [CodexActivitySnapshot] = []
    private let nativeWidget = NativeWidgetBridge()
    private var desktopSnapshot = DesktopWidgetSnapshot.read(from: DesktopWidgetSnapshot.localCacheURL())
    private var activityLoaded = false
    private var analyticsLoaded = false
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var detailPresenter = AlfredPanelPresenter(controller: panel)
    private var threadCycle = RecentThreadCycle()
    private let panel = QuotaPanelViewController()
    private lazy var lineDogs = LineDogsCompanionController()
    private let touchBarPresenter = TouchBarPresenter()
    private var latestSnapshot: QuotaSnapshot?
    private var latestActivity = CodexActivitySnapshot.idle
    private var latestAnalytics = UsageAnalyticsSnapshot.empty
    private var timer: Timer?
    private var activityTimer: Timer?
    private var reminderState: BreakReminderState?
    private var deliveredTestNotifications = 0
    private var quotaRefreshCount = 0
    private var activityRefreshCount = 0
    private var lastQuotaError: String?
    private var isRefreshing = false
    private var isTouchBarManuallyHidden = false
    private let codexBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss"
    ]
    private let codexAppNames: Set<String> = [
        "Codex",
        "ChatGPT",
        "Visual Studio Code",
        "Code",
        "Code - Insiders"
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem.button?.title = " ● --%"
        statusItem.button?.image = AlfredTheme.bat(template: true)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Alfred · Codex 周额度与管家服务"
        statusItem.button?.setAccessibilityLabel("Alfred 周额度")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        panel.onRefresh = { [weak self] in
            self?.refresh()
            self?.refreshActivity()
            self?.refreshAnalytics()
            self?.agendaService.refresh()
            self?.isTouchBarManuallyHidden = false
            self?.presentTouchBarIfCodexIsFrontmost(force: true)
        }
        panel.onQuit = { [weak self] in
            self?.detailPresenter.close()
            NSApp.terminate(nil)
        }
        panel.onPetToggle = { [weak self] in
            guard let self else { return }
            self.lineDogs.toggleVisibility()
            self.panel.update(petVisible: self.lineDogs.isVisible)
        }
        panel.onAppearanceChange = { [weak self] in self?.updateAssistantUI() }
        panel.onDesktopToggle = { [weak self] in self?.desktopSticker.toggle(); self?.writeDiagnostics() }
        panel.onDesktopReset = { [weak self] in self?.desktopSticker.resetPosition(); self?.writeDiagnostics() }
        desktopSticker.onVisibilityChange = { [weak self] value in self?.panel.updateDesktop(visible: value) }
        panel.updateDesktop(visible: desktopSticker.isVisible)
        panel.onOpenThread = { [weak self] id in self?.openThread(id) }
        panel.assistantBoard.onAcknowledge = { [weak self] id in self?.acknowledgeNotice(id) }
        panel.assistantBoard.onOpenNotice = { [weak self] notice in self?.openNotice(notice) }
        panel.assistantBoard.onSnooze = { [weak self] in self?.workBreakReminder.snooze() }
        panel.assistantBoard.onBreakDone = { [weak self] in self?.workBreakReminder.completedBreak() }
        panel.assistantBoard.onExport = { [weak self] in self?.exportDailyBrief() }
        panel.assistantBoard.onOpenButler = { [weak self] in self?.openButler() }
        panel.assistantBoard.onCallButler = { [weak self] in self?.openButler(voiceEntry: true) }
        panel.assistantBoard.onConnectAgenda = { [weak self] in self?.agendaService.requestAccess() }
        panel.assistantBoard.onOpenCalendar = { [weak self] in self?.openAgendaApp(reminders: false) }
        panel.assistantBoard.onOpenReminders = { [weak self] in self?.openAgendaApp(reminders: true) }
        agendaService.onChange = { [weak self] value in
            guard let self else { return }
            agendaText = value.description
            panel.assistantBoard.agendaConnected = value.eventsAccess == .allowed && value.remindersAccess == .allowed
            if value.error == nil {
                for notice in AgendaReminderPolicy.notices(for: value.selection) { _ = inbox.post(notice) }
            }
            updateAssistantUI(); writeDiagnostics()
        }
        inbox.onChange = { [weak self] in self?.updateAssistantUI() }
        inbox.onNotify = { [weak self] notice in self?.notify(notice) }
        workBreakReminder.onBreakDue = { [weak self] in
            guard let self, !inbox.notices.contains(where: { $0.kind == "break" }) else { return }
            _ = inbox.post(AssistantNotice(id: "break-\(Int64(Date().timeIntervalSince1970))", kind: "break", title: "少爷，蝙蝠洞该整备了", body: "请起身走两步，舒展肩背。可以稍后5分钟；活动后点「已活动」，开始下一轮。", createdAt: Date()))
        }
        workBreakReminder.onBreakHandled = { [weak self] in
            guard let self else { return }
            for notice in inbox.notices where notice.kind == "break" { inbox.acknowledge(notice.id) }
        }
        workBreakReminder.onNoticeAction = { [weak self] id, action in
            guard let self else { return }
            if action == "notice-read" { acknowledgeNotice(id) }
            else if let notice = inbox.notices.first(where: { $0.id == id }) { openNotice(notice) }
            else { showAssistantPopover() }
        }
        panel.onOpenCodex = { [weak self] in self?.detailPresenter.close(); self?.activateCodexApp() }
        panel.update(petVisible: lineDogs.isVisible)
        panel.onTestNotification = { [weak self] in self?.workBreakReminder.testNotification() }
        panel.onNotificationSettings = { [weak self] in self?.workBreakReminder.openNotificationSettings() }
        panel.onReminderToggle = { [weak self] in
            self?.workBreakReminder.toggle()
        }
        workBreakReminder.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.reminderState = state
                self?.panel.update(reminder: state)
                self?.updateAssistantUI()
                self?.writeDiagnostics()
            }
        }
        lineDogs.onOpenCodex = { [weak self] in
            self?.activateCodexApp()
        }
        touchBarPresenter.onClose = { [weak self] in
            self?.isTouchBarManuallyHidden = true
        }
        touchBarPresenter.onStatusClick = { [weak self] in
            guard let self else { return }
            if let item = threadCycle.next(), let id = item.sessionID {
                touchBarPresenter.update(activity: threadCycle.displayed(primary: latestActivity))
                openThread(id)
            } else { activateCodexApp() }
        }
        touchBarPresenter.onButlerClick = { [weak self] in self?.openButler() }
        touchBarPresenter.onQuotaClick = { [weak self] in self?.openOverviewAndRefresh() }
        latestAnalytics = analyticsService.cachedSnapshot()
        panel.update(analytics: latestAnalytics)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        refresh()
        refreshActivity()
        refreshAnalytics()
        workBreakReminder.start()
        agendaService.start()
        if CommandLine.arguments.contains("--connect-agenda") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.agendaService.requestAccess() }
        }
        if CommandLine.arguments.contains("--test-notification") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.workBreakReminder.testNotification() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] notifications in
                    let count = notifications.filter { $0.request.content.title == AlfredNotifications.testTitle }.count
                    DispatchQueue.main.async { [weak self] in self?.deliveredTestNotifications = count; self?.writeDiagnostics() }
                }
            }
        }
        presentTouchBarIfCodexIsFrontmost(force: true)
        scheduleTouchBarPresentationRetry()

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshActivity()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !detailPresenter.isShown { togglePopover() }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = DesktopWidgetSnapshot.action(for: url) else { continue }
            switch action {
            case "overview": openOverviewAndRefresh()
            case "refresh":
                if !detailPresenter.isShown { panel.showOverviewPage(); togglePopover() }
                panel.onRefresh?()
            case "butler": openButler()
            case "task":
                if let id = latestActivity.sessionID { openThread(id) } else { activateCodexApp() }
            case "calendar": openAgendaApp(reminders: false)
            case "reminders": openAgendaApp(reminders: true)
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        activityTimer?.invalidate()
        workBreakReminder.stop()
        agendaService.stop()
        desktopSticker.stop()
        lineDogs.shutdown()
        detailPresenter.close()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if detailPresenter.isShown {
            detailPresenter.close()
        } else {
            workBreakReminder.refreshAuthorization()
            panel.update(petVisible: lineDogs.isVisible)
            detailPresenter.show(anchor: button)
            refreshAnalytics()
            isTouchBarManuallyHidden = false
            presentTouchBarIfCodexIsFrontmost(force: true)
        }
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard isCodex(app) else { return }
        isTouchBarManuallyHidden = false
        refreshActivity()
        touchBarPresenter.forcePresentSystemModal()
        if latestSnapshot == nil {
            refresh()
        }
    }

    private func presentTouchBarIfCodexIsFrontmost(force: Bool = false) {
        guard !isTouchBarManuallyHidden else { return }
        guard isCodex(NSWorkspace.shared.frontmostApplication) else { return }
        if force {
            touchBarPresenter.forcePresentSystemModal()
        } else {
            touchBarPresenter.presentSystemModal()
        }
    }

    private func scheduleTouchBarPresentationRetry() {
        for delay in [1.0, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.presentTouchBarIfCodexIsFrontmost(force: true)
            }
        }
    }

    private func isCodex(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        if let bundleIdentifier = app.bundleIdentifier,
           codexBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        guard let localizedName = app.localizedName else {
            return false
        }
        return codexAppNames.contains(localizedName)
    }

    private func activateCodexApp() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { runningApp in
            if let bundleIdentifier = runningApp.bundleIdentifier,
               bundleIdentifier == "com.openai.codex" {
                return true
            }
            return runningApp.localizedName == "Codex" || runningApp.localizedName == "ChatGPT"
        }) {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            activateCodexWithAppleScript()
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            activateCodexWithAppleScript()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, _ in
            self?.activateCodexWithAppleScript()
        }
    }

    private func activateCodexWithAppleScript() {
        var error: NSDictionary?
        NSAppleScript(source: #"tell application id "com.openai.codex" to activate"#)?.executeAndReturnError(&error)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        quotaRefreshCount += 1
        panel.setLoading(keepingExistingData: latestSnapshot != nil)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try self.client.readRateLimits()
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.lastQuotaError = nil
                    self.latestSnapshot = snapshot
                    self.apply(snapshot: snapshot)
                    if let weekly = snapshot.weekly {
                        self.analyticsService.recordWeeklyQuota(weekly) { [weak self = self] analytics in
                            self?.apply(analytics: analytics)
                        }
                    } else {
                        self.refreshAnalytics()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.lastQuotaError = error.localizedDescription
                    self.panel.show(error: error)
                    if let latestSnapshot = self.latestSnapshot {
                        self.applyStatusTitle(snapshot: latestSnapshot)
                    } else {
                        self.statusItem.button?.title = " ● ?"
                    }
                    self.refreshAnalytics()
                }
            }
        }
    }

    private func refreshActivity() {
        activityRefreshCount += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let activities = self.statusMonitor.readActivities()
            let activity = activities.max { $0.kind.priority == $1.kind.priority ? $0.updatedAt < $1.updatedAt : $0.kind.priority < $1.kind.priority } ?? .idle
            DispatchQueue.main.async {
                self.latestActivity = activity
                self.latestActivities = activities
                self.activityLoaded = true
                self.threadCycle.update(primary: activity, activities: activities)
                self.inbox.observe(activities: activities)
                self.panel.update(activity: activity)
                self.lineDogs.update(activity: activity)
                self.touchBarPresenter.update(activity: self.threadCycle.displayed(primary: activity))
                self.presentTouchBarIfCodexIsFrontmost()
                self.updateAssistantUI()
                self.writeDiagnostics()
            }
        }
    }

    private func writeDiagnostics() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--diagnostics"), args.count > index + 1 else { return }
        var data: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
            "bundlePath": Bundle.main.bundlePath, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "development",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "development",
            "pet": lineDogs.diagnostics, "quotaRefreshCount": quotaRefreshCount, "activityRefreshCount": activityRefreshCount,
            "activityKind": latestActivity.kind.rawValue, "analyticsTokens": latestAnalytics.allTime.tokens.total,
            "confidence": latestAnalytics.confidence.rawValue, "rateCard": latestAnalytics.rateCardVersion]
        if let state = reminderState {
            data["reminder"] = ["enabled": state.isEnabled, "authorization": String(describing: state.authorization), "remainingMinutes": state.remainingMinutes, "paused": state.isPaused, "diagnostic": state.diagnostic ?? "", "deliveredTestNotifications": deliveredTestNotifications]
        }
        data["interface"] = panel.interfaceDiagnostics
        data["detailPanel"] = ["visible": detailPresenter.isShown, "nonactivating": true, "joinsAllSpaces": true, "fullScreenAuxiliary": true, "cycleCount": threadCycle.candidates.count]
        data["assistant"] = ["unreadCount": inbox.unreadCount, "pendingBreak": reminderState?.pending ?? false, "activeSecondsToday": workBreakReminder.activeSecondsToday, "completedBreaksToday": workBreakReminder.breaksToday, "notificationError": assistantNotificationError ?? "", "pace": currentPace?.description ?? "unavailable"]
        data["agenda"] = agendaService.snapshot.diagnostics
        data["dailyBrief"] = ["source": "local-calendar-reminders-codex", "cloudSync": false, "automaticExternalSend": false]
        data["desktopWidget"] = nativeWidget.diagnostics
        data["desktopSticker"] = desktopSticker.diagnostics
        data["butler"] = ["homeURL": "codex://dots", "voiceBehavior": "open-confirmed-home-then-user-phone-button", "automaticCall": false,
            "lastNavigationAction": lastButlerAction, "preserveExistingConversation": true]
        data["weeklyRemaining"] = latestSnapshot?.weekly?.remainingPercent
        data["quotaError"] = lastQuotaError
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
    }

    private func refreshAnalytics() {
        analyticsService.refresh { [weak self] analytics in
            self?.apply(analytics: analytics)
        }
    }

    private func apply(analytics: UsageAnalyticsSnapshot) {
        latestAnalytics = analytics
        analyticsLoaded = true
        panel.update(analytics: analytics)
        updateAssistantUI()
    }

    private func apply(snapshot: QuotaSnapshot) {
        panel.update(snapshot: snapshot)
        if let pace = currentPace { inbox.observe(pace: pace) }
        updateAssistantUI()
        touchBarPresenter.update(snapshot: snapshot)
        presentTouchBarIfCodexIsFrontmost()
        applyStatusTitle(snapshot: snapshot)
        updateAssistantUI()
    }

    private var currentPace: QuotaPace? {
        guard let snapshot = latestSnapshot, let weekly = snapshot.weekly else { return nil }
        return QuotaPace.calculate(window: weekly, fetchedAt: snapshot.fetchedAt, now: Date())
    }
    private func updateAssistantUI() {
        let brief = LocalDailyBrief.make(analytics: latestAnalytics, activities: latestActivities, agenda: agendaService.snapshot,
            activeSeconds: workBreakReminder.activeSecondsToday, breaks: workBreakReminder.breaksToday)
        currentBrief = brief.summary; currentTodos = brief.todos
        panel.assistantBoard.updateDailyTodos(currentTodos)
        panel.updateAssistant(notices: inbox.notices, pace: currentPace, brief: currentBrief, agenda: agendaText,
                              butlerStatus: assistantNotificationError.map { butlerStatus + "\n通知：" + $0 } ?? butlerStatus)
        let percent = latestSnapshot?.weekly.map { "\(Int($0.remainingPercent.rounded()))%" } ?? (lastQuotaError == nil ? "--%" : "?")
        let title = " ● " + percent
        let string = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        string.addAttribute(.foregroundColor, value: inbox.unreadCount > 0 ? NSColor.systemOrange : NSColor.systemGray, range: NSRange(location: 1, length: 1))
        statusItem.button?.attributedTitle = string
        touchBarPresenter.updateUnread(inbox.unreadCount > 0)
        statusItem.button?.toolTip = "Alfred · 待处理 \(inbox.unreadCount) · 周额度 \(percent)"
        updateDesktopWidget()
    }
    private func updateDesktopWidget() {
        let agenda = agendaService.snapshot
        let quotaReady = latestSnapshot != nil || lastQuotaError != nil
        let agendaReady = agenda.fetchedAt != nil || agenda.error != nil
        // Never publish an empty startup placeholder over a valid system widget.
        guard quotaReady && agendaReady || desktopSnapshot != nil else { return }
        var value = DesktopWidgetSnapshot(updatedAt: Date(), quotaFetchedAt: latestSnapshot?.fetchedAt,
            remaining: latestSnapshot?.weekly?.remainingPercent, resetDate: latestSnapshot?.weekly?.resetDate,
            quotaFailed: lastQuotaError != nil, pace: currentPace?.description.components(separatedBy: "\n").last ?? "周额度节奏待计算",
            activity: latestActivity.displayText, unread: inbox.unreadCount,
            todayTokens: String(format: "%.2fM", Double(latestAnalytics.today.tokens.total) / 1_000_000),
            appearance: UserDefaults.standard.string(forKey: "Alfred.appearance") ?? "system")
        value.agendaFetchedAt = agenda.fetchedAt
        if let top = latestAnalytics.dailyBuckets.first(where: { Calendar.current.isDateInToday($0.date) })?.topConversations.first {
            value.briefHeadline = "今日主线 · " + top.title
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN"); date.dateFormat = "M/d E HH:mm"
        if agenda.eventsAccess != .allowed { value.meeting = "日历" + agenda.eventsAccess.label }
        else if let meeting = agenda.selection.nextMeeting { value.meeting = meeting.title; value.meetingTime = date.string(from: meeting.start) }
        else { value.meeting = agenda.error == nil ? "未来30天暂无定时日程" : "日程读取失败"; value.meetingTime = "打开日历查看安排" }
        if agenda.remindersAccess != .allowed { value.todo = "提醒事项" + agenda.remindersAccess.label }
        else if let todo = agenda.selection.priorityTodo {
            value.todo = todo.title
            date.dateFormat = todo.dueHasTime ? "M/d E HH:mm" : "M/d E"
            value.todoTime = todo.due.map { "截止 " + date.string(from: $0) } ?? "尚待完成"
        } else { value.todo = agenda.error == nil ? "暂无未完成事项" : "待办读取失败"; value.todoTime = "打开提醒事项查看" }
        value = value.preservingLoadingFields(from: desktopSnapshot, quotaReady: quotaReady, agendaReady: agendaReady,
            activityReady: activityLoaded, analyticsReady: analyticsLoaded)
        desktopSnapshot = value
        desktopSticker.update(value)
        nativeWidget.update(value)
    }
    private func notify(_ notice: AssistantNotice) {
        guard notice.kind != "break" && notice.kind != "voice" else { return } // Break backend owns its alarm; voice guidance stays in the inbox.
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let prepared = AlfredNotifications.prepare(title: notice.title, body: notice.body, kind: notice.kind,
                category: "alfred-notice", noticeID: notice.id)
            center.add(UNNotificationRequest(identifier: notice.id, content: prepared.content, trigger: nil)) { [weak self] error in
                prepared.cleanup()
                if let message = error?.localizedDescription ?? prepared.attachmentError.map({ "蝙蝠插图未能附加：" + $0 }) {
                    DispatchQueue.main.async { self?.assistantNotificationError = message; self?.updateAssistantUI() }
                }
            }
        }
    }
    private func acknowledgeNotice(_ id: String) {
        inbox.acknowledge(id)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
    private func openThread(_ id: String) {
        guard UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/" + id) else { activateCodexApp(); return }
        detailPresenter.close()
        if NSWorkspace.shared.open(url) { butlerNavigationGate.didNavigateElsewhere() }
        else { activateCodexApp() }
    }
    private func openNotice(_ notice: AssistantNotice) {
        if let id = notice.threadID { openThread(id) }
        else if notice.kind == "calendar" { openAgendaApp(reminders: false) }
        else if notice.kind == "todo" { openAgendaApp(reminders: true) }
        else { showAssistantPopover() }
        // Opening a task never approves or answers it. It remains pinned until explicitly read.
    }
    private func showAssistantPopover() {
        panel.showAssistantPage()
        if !detailPresenter.isShown { togglePopover() }
    }
    private func openOverviewAndRefresh() {
        if detailPresenter.isShown { detailPresenter.close(); writeDiagnostics(); return }
        panel.showOverviewPage()
        togglePopover()
        refresh(); refreshActivity(); refreshAnalytics(); agendaService.refresh()
    }
    private func openAgendaApp(reminders: Bool) {
        let id = reminders ? "com.apple.reminders" : "com.apple.iCal"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        detailPresenter.close(); NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    private func openButler(voiceEntry: Bool = false) {
        detailPresenter.close()
        let host = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.openai.codex" }
        let route = host.flatMap { windowRouteReader.read(processID: $0.processIdentifier, launchedAt: $0.launchDate) }
        let action = butlerNavigationGate.action(processID: host?.processIdentifier, route: route)
        var opened = false
        if action == .focus, let host {
            // Already showing Dot: no URL event, no re-entry through /dots, no AppleScript or key synthesis.
            opened = host.isActive || host.activate(options: [.activateIgnoringOtherApps])
            if opened { lastButlerAction = "focus-existing" }
        }
        if !opened, let url = URL(string: "codex://dots") {
            opened = NSWorkspace.shared.open(url)
            butlerNavigationGate.didRequestNavigation(accepted: opened)
            lastButlerAction = opened ? "navigate-home" : "failed"
        }
        guard opened else {
            assistantNotificationError = "Your dot 未能打开，请在 Codex 左侧打开管家。"; updateAssistantUI(); return
        }
        writeDiagnostics()
        if voiceEntry {
            _ = inbox.post(AssistantNotice(id: "voice-guide-" + UUID().uuidString, kind: "voice", title: "少爷，请点管家的电话按钮",
                body: "已请求打开 Your dot。请在管家页面点电话按钮开始语音；当前没有可用的外部自动拨号入口。", createdAt: Date()))
        }
    }
    private func exportDailyBrief() {
        let save = NSSavePanel(); save.nameFieldStringValue = "Alfred-蝙蝠洞日报与待办.md"
        save.begin { [weak self] response in
            guard response == .OK, let url = save.url, let self else { return }
            do { try (currentBrief + "\n\n" + currentTodos).write(to: url, atomically: true, encoding: .utf8) }
            catch { assistantNotificationError = "小结导出失败：" + error.localizedDescription; updateAssistantUI() }
        }
    }

    private func applyStatusTitle(snapshot: QuotaSnapshot) {
        if let weekly = snapshot.weekly {
            statusItem.button?.title = " ● \(Int(weekly.remainingPercent.rounded()))%"
        } else {
            statusItem.button?.title = " ● --"
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--agenda" {
    exit(AgendaWorkflowCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}
if Bundle.main.object(forInfoDictionaryKey: "AlfredAgendaOnly") as? Bool == true {
    FileHandle.standardError.write(Data("This development bundle only runs with --agenda; no assistant service started.\n".utf8))
    exit(2)
}

let app = NSApplication.shared
// Also resolve the icon explicitly for direct executable/login-item launches.
// Notification attachments cannot replace the system's left-hand app icon.
if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
   let iconURL = Bundle.main.url(forResource: iconName,
                                withExtension: iconName.hasSuffix(".icns") ? nil : "icns"),
   let icon = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = icon
}
if let index = CommandLine.arguments.firstIndex(of: "--verify-desktop"), CommandLine.arguments.count > index + 1 {
    verifyDesktopSticker(folder: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--verify-butler-navigation"), CommandLine.arguments.count > index + 1 {
    verifyButlerNavigation(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
} else if let index = CommandLine.arguments.firstIndex(of: "--verify-panel"), CommandLine.arguments.count > index + 1 {
    verifyDetailPanel(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--verify-overview"), CommandLine.arguments.count > index + 1 {
    verifyOverviewAppearance(folder: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
} else if let index = CommandLine.arguments.firstIndex(of: "--verify-notification"), CommandLine.arguments.count > index + 1 {
    verifyNotificationAppearance(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    app.run()
} else if CommandLine.arguments.contains("--inspect-interface") {
    inspectInterfaceVerification()
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--render-interface"), CommandLine.arguments.count > index + 1 {
    renderInterfaceVerification(folder: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--verify-pet"), CommandLine.arguments.count > index + 1 {
    runPetVerification(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    app.run()
} else {
    // Prevent an old login item or a manual second launch from starting a second assistant.
    let other = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if Bundle.main.bundleIdentifier == "local.codex.quota-bar", other != nil { exit(0) }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
