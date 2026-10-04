import Foundation

/// Ordered, top-level lifecycle signals. Output text and quoted prompts are never signals.
struct ActivityLogState {
    var active: Bool?
    var calls: [String: CodexActivityKind] = [:]
    var questions = Set<String>()
    var planMode = false
    var planReview = false
    var updatedAt: Date?
    var completedAt: Date?
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    mutating func consume(_ row: [String: Any], fallbackDate: Date) {
        guard let payload = row["payload"] as? [String: Any] else { return }
        let date = (row["timestamp"] as? String).flatMap { Self.fractional.date(from: $0) ?? Self.plain.date(from: $0) } ?? fallbackDate
        let type = payload["type"] as? String ?? ""
        func isFinal(_ value: Any?) -> Bool { ["final_answer", "final"].contains(value as? String ?? "") }
        if row["type"] as? String == "turn_context" {
            let collaboration = payload["collaboration_mode"]
            planMode = (collaboration as? String)?.lowercased() == "plan"
                || ((collaboration as? [String: Any])?["mode"] as? String)?.lowercased() == "plan"
                || (payload["collaboration_mode_kind"] as? String)?.lowercased() == "plan"
            return
        }
        if row["type"] as? String == "event_msg" {
            switch type {
            case "user_message":
                active = true; calls.removeAll(); questions.removeAll(); planReview = false; completedAt = nil
            case "task_started":
                active = true; calls.removeAll(); completedAt = nil
            case "task_complete", "task_completed":
                active = false; calls.removeAll(); completedAt = date
            case "turn_aborted":
                active = false; calls.removeAll(); questions.removeAll(); planReview = false; completedAt = nil
            case "agent_message":
                if isFinal(payload["phase"]) { active = false; calls.removeAll(); completedAt = date }
                else { active = true; completedAt = nil }
            case "agent_reasoning", "token_count":
                guard active != false else { return }
                active = true
            case "approval_requested", "exec_approval_request", "apply_patch_approval_request":
                active = true; calls[payload["call_id"] as? String ?? "approval"] = .waitingApproval
            default: return
            }
            updatedAt = date; return
        }
        guard row["type"] as? String == "response_item" else { return }
        switch type {
        case "message":
            if payload["role"] as? String == "user" {
                active = true; calls.removeAll(); questions.removeAll(); planReview = false; completedAt = nil
            } else if payload["role"] as? String == "assistant" {
                if isFinal(payload["phase"]) { active = false; calls.removeAll(); completedAt = date }
                else { active = true; completedAt = nil }
            } else { return }
        case "reasoning": active = true; completedAt = nil
        case "function_call", "custom_tool_call":
            guard let id = payload["call_id"] as? String else { return }
            active = true; completedAt = nil
            let name = payload["name"] as? String ?? ""
            if name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async") { questions.insert(id) }
            if name.hasSuffix("update_plan") && planMode { planReview = true }
            if payload["status"] as? String != "completed" { calls[id] = Self.toolKind(name) }
        case "function_call_output", "custom_tool_call_output":
            guard let id = payload["call_id"] as? String else { return }
            calls.removeValue(forKey: id)
            // A queued async question is still unanswered; a real answer may finish a blocking question.
            if let text = payload["output"] as? String, let data = text.data(using: .utf8),
               let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = answer["answers"] as? [String: Any], !answers.isEmpty { questions.remove(id) }
            guard active != false else { return } // Late output cannot revive a completed turn.
            active = true
        default: return
        }
        updatedAt = date
    }
    func kind(now: Date) -> CodexActivityKind {
        if !questions.isEmpty { return .waitingQuestion }
        if planReview && active == false { return .waitingReview }
        guard active == true, let date = updatedAt, now.timeIntervalSince(date) <= 30 * 60 else { return .idle }
        return calls.values.max(by: { $0.priority < $1.priority }) ?? .thinking
    }
    private static func toolKind(_ name: String) -> CodexActivityKind {
        if name.hasSuffix("requestApproval") { return .waitingApproval }
        if name.hasSuffix("exec_command") || name.hasSuffix("write_stdin") { return .command }
        if name.hasSuffix("apply_patch") { return .editing }
        return .tool
    }
}

struct RecentThreadCycle {
    private(set) var candidates: [CodexActivitySnapshot] = []
    private var selectedID: String?
    private var primaryID: String?
    private var lastTap: Date?
    mutating func update(primary: CodexActivitySnapshot, activities: [CodexActivitySnapshot]) {
        if primaryID != primary.sessionID { selectedID = nil; lastTap = nil }
        primaryID = primary.sessionID
        let completed = activities.filter { $0.kind == .idle && $0.completedAt != nil }.sorted {
            $0.updatedAt == $1.updatedAt ? ($0.sessionID ?? "") < ($1.sessionID ?? "") : $0.updatedAt > $1.updatedAt
        }
        var ids = Set<String>()
        candidates = ([primary] + completed).filter { item in
            guard let id = item.sessionID, UUID(uuidString: id) != nil else { return false }
            return ids.insert(id).inserted
        }.prefix(5).map { $0 }
        if !candidates.contains(where: { $0.sessionID == selectedID }) { selectedID = nil }
    }
    mutating func next(now: Date = Date()) -> CodexActivitySnapshot? {
        guard !candidates.isEmpty else { return nil }
        if let lastTap, now.timeIntervalSince(lastTap) > 45 { selectedID = nil }
        let index = selectedID.flatMap { id in candidates.firstIndex { $0.sessionID == id } }.map { ($0 + 1) % candidates.count } ?? 0
        selectedID = candidates[index].sessionID; lastTap = now
        return candidates[index]
    }
    func displayed(primary: CodexActivitySnapshot, now: Date = Date()) -> CodexActivitySnapshot {
        guard let lastTap, now.timeIntervalSince(lastTap) <= 45,
              let index = candidates.firstIndex(where: { $0.sessionID == selectedID }), index > 0 else { return primary }
        let item = candidates[index]
        return CodexActivitySnapshot(kind: item.kind, sessionName: (item.sessionName ?? "Codex任务") + " · 回看 \(index + 1)/\(candidates.count)", updatedAt: item.updatedAt, sessionID: item.sessionID, completedAt: item.completedAt)
    }
}
