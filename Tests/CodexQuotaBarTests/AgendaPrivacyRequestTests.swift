import Foundation
import Testing
@testable import CodexQuotaBar

private final class PrivacySimulation {
    var values: [AgendaEntity: [String]] = [.event: ["notDetermined", "fullAccess"], .reminder: ["notDetermined", "fullAccess"]]
    var callbacks: [AgendaEntity: AgendaPrivacyCallback] = [:]
    var requests: [AgendaEntity] = [], statusEntities: [AgendaEntity] = []
    var waits = 0
    func status(_ entity: AgendaEntity) -> String {
        statusEntities.append(entity)
        let result = values[entity]?.first ?? "unknown"
        if (values[entity]?.count ?? 0) > 1 { values[entity]?.removeFirst() }
        return result
    }
    func request(_ entity: AgendaEntity) -> AgendaPrivacyCallback {
        requests.append(entity)
        return callbacks[entity] ?? AgendaPrivacyCallback(granted: true, error: nil)
    }
    func run(_ selected: [AgendaEntity] = [.event], maxRechecks: Int = 10) throws -> AgendaPrivacyReport {
        try AgendaPrivacyRequest.run(entities: selected, maxRechecks: maxRechecks, status: status, request: request, wait: { self.waits += 1 })
    }
}
struct AgendaPrivacyRequestTests {
    @Test func calendarOnlyCallsEventExactlyOnceAndNeverTouchesReminders() throws {
        let simulation = PrivacySimulation(), command = "request-calendar-access"
        let selected = try AgendaPrivacyCommand.entities(command: command, arguments: [command, "--user-approved-privacy-request"])
        let report = try simulation.run(selected)
        #expect(report.status == "verified" && simulation.requests == [.event])
        #expect(simulation.statusEntities.allSatisfy { $0 == .event } && report.selectedEntities == [.event])
        #expect(report.results.count == 1 && report.results[0].requestCount == 1)
        #expect(report.AppleReads == "none" && report.AppleWrites == "none")
    }
    @Test func alreadyAuthorizedDoesNotRequestAgain() throws {
        for value in ["fullAccess", "authorized-legacy"] {
            let simulation = PrivacySimulation(); simulation.values[.event] = [value]
            let report = try simulation.run()
            #expect(report.status == "verified" && report.results[0].state == "already-authorized")
            #expect(simulation.requests.isEmpty && simulation.waits == 0 && report.results[0].requestCount == 0)
        }
    }
    @Test func explicitApprovalFlagAndExactSelectionRequired() throws {
        for args in [["request-calendar-access"], ["request-calendar-access", "--user-approved-privacy-request", "reminders"], ["request-calendar-access", "--wrong"]] {
            #expect(throws: (any Error).self) { try AgendaPrivacyCommand.entities(command: "request-calendar-access", arguments: args) }
        }
        let simulation = PrivacySimulation()
        for selected in [[], [.reminder], [.event, .event]] as [[AgendaEntity]] {
            #expect(throws: (any Error).self) { try simulation.run(selected) }
        }
        #expect(simulation.requests.isEmpty && simulation.statusEntities.isEmpty)
    }
    @Test func transientGrantedStatusRechecksOnlyThenConfirms() throws {
        let simulation = PrivacySimulation(); simulation.values[.event] = ["notDetermined", "notDetermined", "notDetermined", "fullAccess"]
        let report = try simulation.run()
        #expect(report.status == "verified" && report.results[0].callbackGranted == true)
        #expect(report.results[0].after == "fullAccess" && report.results[0].statusChecks == 3)
        #expect(simulation.requests == [.event] && simulation.waits == 2)
    }
    @Test func unresolvedGrantedStatusIsUnknownAndNeverContinuesToReminders() throws {
        let simulation = PrivacySimulation(); simulation.values[.event] = ["notDetermined"]
        do {
            _ = try simulation.run([.event, .reminder]); Issue.record("Must be unknown")
        } catch let failure as AgendaPrivacyFailure {
            #expect(failure.report.status == "unknown" && failure.report.results[0].state == "unknown")
            #expect(failure.report.results[0].callbackGranted == true && failure.report.results[0].after == "notDetermined")
            #expect(failure.report.results[0].statusChecks == 11 && simulation.waits == 10)
        }
        #expect(simulation.requests == [.event] && simulation.statusEntities.allSatisfy { $0 == .event })
    }
    @Test func deniedOrRestrictedBeforeRequestStopsAllAPIs() throws {
        for value in ["denied", "restricted"] {
            let simulation = PrivacySimulation(); simulation.values[.event] = [value]
            do { _ = try simulation.run([.event, .reminder]); Issue.record("Must stop") }
            catch let failure as AgendaPrivacyFailure { #expect(failure.report.status == "blocked" && failure.report.results[0].requestCount == 0) }
            #expect(simulation.requests.isEmpty && simulation.waits == 0 && simulation.statusEntities == [.event])
        }
    }
    @Test func falseCallbackDoesNotPollOrInferDeniedFromUndetermined() throws {
        let simulation = PrivacySimulation(); simulation.callbacks[.event] = AgendaPrivacyCallback(granted: false, error: nil)
        do { _ = try simulation.run([.event, .reminder]); Issue.record("Must stop") }
        catch let failure as AgendaPrivacyFailure {
            #expect(failure.report.status == "blocked" && failure.report.results[0].state == "not-granted")
            #expect(failure.report.results[0].after == nil && failure.report.results[0].callbackGranted == false)
        }
        #expect(simulation.requests == [.event] && simulation.waits == 0 && simulation.statusEntities == [.event])
    }
    @Test func nativeErrorStopsImmediatelyEvenWithTrueCallback() throws {
        let simulation = PrivacySimulation(); simulation.callbacks[.event] = AgendaPrivacyCallback(granted: true, error: "Synthetic NSError code=1")
        do { _ = try simulation.run([.event, .reminder]); Issue.record("Must stop") }
        catch let failure as AgendaPrivacyFailure {
            #expect(failure.report.results[0].state == "failed" && failure.report.results[0].callbackError == "Synthetic NSError code=1")
            #expect(failure.report.status == "blocked")
        }
        #expect(simulation.requests == [.event] && simulation.statusEntities == [.event] && simulation.waits == 0)
    }
    @Test func timeoutIsUnknownAndNeverRetriesOrRequestsNextEntity() throws {
        let simulation = PrivacySimulation(); simulation.callbacks[.event] = AgendaPrivacyCallback(granted: nil, error: nil, timedOut: true)
        do { _ = try simulation.run([.event, .reminder]); Issue.record("Must stop") }
        catch let failure as AgendaPrivacyFailure { #expect(failure.report.status == "unknown" && failure.report.results[0].state == "timeout") }
        #expect(simulation.requests == [.event] && simulation.statusEntities == [.event] && simulation.waits == 0)
    }
    @Test func statusRevokedAfterGrantedStopsWithoutExtraChecks() throws {
        let simulation = PrivacySimulation(); simulation.values[.event] = ["notDetermined", "denied", "fullAccess"]
        do { _ = try simulation.run([.event, .reminder]); Issue.record("Must stop") }
        catch let failure as AgendaPrivacyFailure { #expect(failure.report.results[0].after == "denied" && failure.report.status == "blocked") }
        #expect(simulation.requests == [.event] && simulation.waits == 0 && simulation.statusEntities.count == 2)
    }
    @Test func legacyCommandStillRequestsBothInOrderOnlyAfterConfirmedCalendar() throws {
        let simulation = PrivacySimulation(), command = "request-read-access"
        let selected = try AgendaPrivacyCommand.entities(command: command, arguments: [command, "--user-approved-privacy-request"])
        let report = try simulation.run(selected)
        #expect(selected == [.event, .reminder] && simulation.requests == [.event, .reminder])
        #expect(report.status == "verified" && report.results.count == 2)
        #expect(simulation.statusEntities == [.event, .event, .reminder, .reminder])
    }
    @Test func writeOnlyUpgradesCalendarAndZeroRechecksRemainFinite() throws {
        let simulation = PrivacySimulation(); simulation.values[.event] = ["writeOnly", "fullAccess"]
        #expect(try simulation.run().status == "verified" && simulation.requests == [.event])
        let stalled = PrivacySimulation(); stalled.values[.event] = ["notDetermined"]
        do { _ = try stalled.run(maxRechecks: 0); Issue.record("Must be unknown") }
        catch let failure as AgendaPrivacyFailure { #expect(failure.report.results[0].statusChecks == 1 && failure.report.status == "unknown") }
        #expect(stalled.waits == 0 && stalled.requests == [.event])
    }
}
