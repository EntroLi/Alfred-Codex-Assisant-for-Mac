// Experimental App Group probe only; not packaged in the production app.
// Self write/read success does not establish access by the system-hosted widget.
import Foundation

// Sandboxed helper receives only a bounded display snapshot on stdin. It has no
// network, user-file, automation or calendar entitlements, and never reads logs.
@main struct AlfredSnapshotWriter {
static func main() {
let input = FileHandle.standardInput.readData(ofLength: 64 * 1024 + 1)
guard input.count <= 64 * 1024,
      let value = try? JSONDecoder().decode(DesktopWidgetSnapshot.self, from: input),
      value.schema == 1, value.remaining.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
      let url = DesktopWidgetSnapshot.cacheURL() else { exit(2) }
do {
    try input.write(to: url, options: .atomic)
    guard let result = DesktopWidgetSnapshot.read(from: url), result == value else { exit(3) }
    print("snapshot-written-and-read"); exit(0)
} catch { fputs("snapshot-write-failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
}
