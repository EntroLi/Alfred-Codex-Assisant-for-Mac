import Foundation

// Pure sequencing policy. Only the EventKit adapter supplies native closures.
struct AgendaPrivacyCallback {
    var granted: Bool?
    var error: String?
    var timedOut = false
}
struct AgendaPrivacyEntityResult: Codable {
    var entity: AgendaEntity
    var before: String
    var after: String?
    var requestCount = 0
    var callbackGranted: Bool?
    var callbackError: String?
    var statusChecks = 0
    var state: String
}
struct AgendaPrivacyReport: Codable {
    var selectedEntities: [AgendaEntity]
    var startedAt: String
    var finishedAt: String
    var status: String
    var results: [AgendaPrivacyEntityResult]
    var reason: String?
    var privacyRequest = "explicitly selected entities only; no request retry"
    var AppleReads = "none"
    var AppleWrites = "none"
    var bundleID: String? = nil
    var bundlePath: String? = nil
}
struct AgendaPrivacyFailure: Error, CustomStringConvertible {
    var report: AgendaPrivacyReport
    var description: String { report.reason ?? report.status }
}

enum AgendaPrivacyCommand {
    static func entities(command: String, arguments: [String]) throws -> [AgendaEntity] {
        guard arguments == [command, "--user-approved-privacy-request"] else {
            throw AgendaWorkflowError.invalid("Separate explicit user approval for this exact process and selected privacy scope is required")
        }
        switch command {
        case "request-calendar-access": return [.event]
        case "request-reminder-access": return [.reminder]
        case "request-read-access": return [.event, .reminder] // Existing explicit two-entity command.
        default: throw AgendaWorkflowError.invalid("Unknown privacy command")
        }
    }
}

enum AgendaPrivacyRequest {
    static func run(entities: [AgendaEntity], maxRechecks: Int = 10,
                    status: (AgendaEntity) -> String,
                    request: (AgendaEntity) -> AgendaPrivacyCallback,
                    wait: () -> Void) throws -> AgendaPrivacyReport {
        guard entities == [.event] || entities == [.reminder] || entities == [.event, .reminder], (0...20).contains(maxRechecks) else {
            throw AgendaWorkflowError.invalid("Explicit calendar-only, reminder-only or legacy two-entity selection required")
        }
        var report = AgendaPrivacyReport(selectedEntities: entities, startedAt: AgendaWorkflowCodec.now(),
            finishedAt: AgendaWorkflowCodec.now(), status: "pending", results: [])
        func allowed(_ value: String) -> Bool { value == "fullAccess" || value == "authorized-legacy" }
        func stop(_ row: AgendaPrivacyEntityResult, reason: String, unknown: Bool = false) throws -> Never {
            report.results.append(row); report.status = unknown ? "unknown" : "blocked"
            report.reason = reason + "; no second request and no remaining entity request"
            report.finishedAt = AgendaWorkflowCodec.now()
            throw AgendaPrivacyFailure(report: report)
        }
        for entity in entities {
            let before = status(entity)
            var row = AgendaPrivacyEntityResult(entity: entity, before: before, after: before, state: "pending")
            if allowed(before) {
                row.state = "already-authorized"; report.results.append(row); continue
            }
            guard before == "notDetermined" || entity == .event && before == "writeOnly" else {
                row.state = before == "denied" || before == "restricted" ? "denied-or-restricted" : "unknown"
                try stop(row, reason: "Selected entity has no requestable permission state: " + before, unknown: row.state == "unknown")
            }
            row.requestCount = 1
            let callback = request(entity)
            row.callbackGranted = callback.granted; row.callbackError = callback.error; row.after = nil
            if callback.timedOut {
                row.state = "timeout"
                try stop(row, reason: "Privacy response deadline elapsed; user response or final status is unknown", unknown: true)
            }
            if callback.error != nil {
                row.state = "failed"
                try stop(row, reason: "Native privacy callback failed; permission not inferred")
            }
            guard callback.granted == true else {
                row.state = callback.granted == false ? "not-granted" : "unknown"
                try stop(row, reason: "Callback did not grant access; notDetermined does not mean user denial", unknown: callback.granted == nil)
            }
            // A granted callback is not sufficient proof of usable permission. Read status only,
            // at most 11 times over 2 seconds; never call a request API during these rechecks.
            for check in 0...maxRechecks {
                let after = status(entity); row.after = after; row.statusChecks += 1
                if allowed(after) { row.state = "authorized"; break }
                if after == "denied" || after == "restricted" {
                    row.state = "denied-or-restricted"
                    try stop(row, reason: "Granted callback and denied/restricted status disagree; stop without retry")
                }
                if check < maxRechecks { wait() }
            }
            guard row.state == "authorized" else {
                row.state = "unknown"
                try stop(row, reason: "Granted callback, but bounded status checks did not confirm full access; inspect status later", unknown: true)
            }
            report.results.append(row)
        }
        report.status = "verified"; report.finishedAt = AgendaWorkflowCodec.now()
        return report
    }
}
