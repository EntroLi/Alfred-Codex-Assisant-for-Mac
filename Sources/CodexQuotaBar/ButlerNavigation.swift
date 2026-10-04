import Foundation

struct CodexWindowRoute {
    let path: String
    let observedAt: Date
    var isButlerConversation: Bool {
        let parts = (path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").split(separator: "/")
        return parts.count == 2 && ["dots", "o"].contains(String(parts[0])) && UUID(uuidString: String(parts[1])) != nil
    }
}

/// Read only the desktop's existing owner-route metadata, never chat content, drafts or credentials.
/// This is a compatibility signal, not a public host API. Missing/ambiguous signals fall back to navigation.
final class CodexWindowRouteReader {
    private let root: URL
    init(root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/com.openai.codex")) { self.root = root }
    func read(processID: Int32, launchedAt: Date?, now: Date = Date()) -> CodexWindowRoute? {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let folders = Set(([now, now.addingTimeInterval(-86400)] + (launchedAt.map { [$0] } ?? [])).map {
            root.appendingPathComponent(formatter.string(from: $0))
        })
        let files = folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { $0.lastPathComponent.contains("-\(processID)-t0-") && $0.pathExtension == "log" }
        var routes: [String: CodexWindowRoute] = [:], ignored = Set<String>()
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > 8 * 1024 * 1024 ? size - 8 * 1024 * 1024 : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd() else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let observations = Self.observations(text, since: launchedAt, droppingFirstLine: offset > 0)
            ignored.formUnion(observations.ignored)
            for (id, route) in observations.routes where routes[id] == nil || routes[id]!.observedAt < route.observedAt { routes[id] = route }
        }
        ignored.forEach { routes.removeValue(forKey: $0) }
        // A log does not identify the frontmost window among multiple main windows. Never guess.
        return routes.count == 1 ? routes.values.first : nil
    }
    static func observations(_ text: String, since: Date?, droppingFirstLine: Bool = false) -> (routes: [String: CodexWindowRoute], ignored: Set<String>) {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var routes: [String: CodexWindowRoute] = [:], ignored = Set<String>()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if droppingFirstLine && !lines.isEmpty { lines.removeFirst() }
        // The last incomplete log row must not replace a complete route observation.
        if !text.hasSuffix("\n") && !lines.isEmpty { lines.removeLast() }
        for line in lines {
            let marker = "[electron-message-handler] IAB_LIFECYCLE "
            guard line.dropFirst(24).hasPrefix(" info " + marker), let range = line.range(of: marker),
                  let date = formatter.date(from: String(line.prefix(24))), since == nil || date >= since! else { continue }
            let payload = String(line[range.upperBound...])
            let values = payload.split(separator: " ").reduce(into: [String: String]()) { result, item in
                let pair = item.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }
            guard let id = values["windowId"], Int(id) != nil else { continue }
            if payload.hasPrefix("ignored browser sidebar owner sync from auxiliary window") { ignored.insert(id); continue }
            guard payload.hasPrefix("received browser sidebar owner sync "), let path = values["ownerRoutePath"], path.hasPrefix("/") else { continue }
            if routes[id] == nil || routes[id]!.observedAt <= date { routes[id] = CodexWindowRoute(path: path, observedAt: date) }
        }
        return (routes, ignored)
    }
}

struct ButlerNavigationGate {
    enum Action { case focus, navigate }
    private var processID: Int32?
    private var lastAcceptedRequest: Date?
    private var navigatedElsewhereAt: Date?
    mutating func action(processID: Int32?, route: CodexWindowRoute?, now: Date = Date()) -> Action {
        if self.processID != processID { self.processID = processID; lastAcceptedRequest = nil; navigatedElsewhereAt = nil }
        guard processID != nil else { return .navigate }
        if let route, route.isButlerConversation, navigatedElsewhereAt == nil || route.observedAt >= navigatedElsewhereAt! { return .focus }
        if let lastAcceptedRequest, now.timeIntervalSince(lastAcceptedRequest) < 1.5 { return .focus }
        return .navigate
    }
    mutating func didRequestNavigation(accepted: Bool, now: Date = Date()) { lastAcceptedRequest = accepted ? now : nil }
    mutating func didNavigateElsewhere(now: Date = Date()) { navigatedElsewhereAt = now; lastAcceptedRequest = nil }
}
