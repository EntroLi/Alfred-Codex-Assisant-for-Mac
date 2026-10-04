import AppKit
import Foundation
let paths = Set(CommandLine.arguments.dropFirst())
let matches = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "local.codex.quota-bar" && paths.contains($0.bundleURL?.path ?? "")
}
for app in matches {
    print("Stopping assistant PID \(app.processIdentifier): \(app.bundleURL!.path)")
    guard app.terminate() else { exit(1) }
}
let deadline = Date().addingTimeInterval(10)
while matches.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
exit(matches.contains(where: { !$0.isTerminated }) ? 1 : 0)
