import Foundation
import WidgetKit

final class DesktopWidgetBridge {
    private let url: URL?
    private var previous: DesktopWidgetSnapshot?
    private var lastReload = Date.distantPast
    private var pending: Timer?
    private(set) var error: String?
    private(set) var writes = 0
    init(url: URL? = DesktopWidgetSnapshot.cacheURL()) { self.url = url }
    func update(_ value: DesktopWidgetSnapshot) {
        guard let url else { error = "桌贴共享容器不可用"; return }
        guard previous.map({ !value.sameContent(as: $0) }) ?? true else { return }
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            previous = value; writes += 1; error = nil
            if Date().timeIntervalSince(lastReload) >= 60 { reload() }
            else if pending == nil {
                pending = Timer.scheduledTimer(withTimeInterval: max(1, 60 - Date().timeIntervalSince(lastReload)), repeats: false) { [weak self] _ in self?.reload() }
            }
        } catch { self.error = "桌贴数据更新失败：" + error.localizedDescription }
    }
    private func reload() {
        pending?.invalidate(); pending = nil; lastReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: DesktopWidgetSnapshot.kind)
    }
    func stop() { pending?.invalidate(); pending = nil }
    var diagnostics: [String: Any] {
        ["nativeWidget": true, "family": "systemExtraLarge", "aspect": "4:2", "sharedContainerAvailable": url != nil,
         "snapshotWrites": writes, "error": error ?? "", "reloadRequestMinimumSeconds": 60,
         "systemControlsRefresh": true]
    }
}
