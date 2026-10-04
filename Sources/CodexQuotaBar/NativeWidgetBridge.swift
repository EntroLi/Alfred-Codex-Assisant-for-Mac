import Foundation
import WidgetKit

final class NativeWidgetBridge {
    private let queue = DispatchQueue(label: "alfred.widget.writer", qos: .utility)
    private var previous: DesktopWidgetSnapshot?
    private var busy = false
    private var pending: DesktopWidgetSnapshot?
    private var lastReload = Date.distantPast
    private var delayedReload: Timer?
    private var lastWrite = Date.distantPast
    private var delayedWrite: Timer?
    private var lastQuery = Date.distantPast
    private var configurationCount: Int?
    private var configurationError: Bool = false
    private(set) var error: String?
    private(set) var writes = 0
    var enabled: Bool { Bundle.main.builtInPlugInsURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("AlfredDesktop.appex").path) } ?? false }
    func update(_ value: DesktopWidgetSnapshot) {
        guard enabled else { error = "原生小组件扩展未安装"; return }
        if Date().timeIntervalSince(lastQuery) >= 60 {
            lastQuery = Date()
            WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let items): self?.configurationCount = items.filter { $0.kind == DesktopWidgetSnapshot.kind }.count; self?.configurationError = false
                    case .failure: self?.configurationError = true
                    }
                }
            }
        }
        guard previous.map({ !value.sameContent(as: $0) }) ?? true else { return }
        if busy { pending = value; return }
        if Date().timeIntervalSince(lastWrite) < 30 {
            pending = value
            if delayedWrite == nil {
                delayedWrite = Timer.scheduledTimer(withTimeInterval: max(1, 30 - Date().timeIntervalSince(lastWrite)), repeats: false) { [weak self] _ in
                    guard let self else { return }; self.delayedWrite = nil
                    if let latest = self.pending { self.pending = nil; self.update(latest) }
                }
            }
            return
        }
        guard let url = DesktopWidgetSnapshot.localCacheURL() else { error = "本机显示快照位置不可用"; return }
        busy = true; lastWrite = Date()
        queue.async { [weak self] in
            var succeeded = false; var message: String?
            do {
                let data = try JSONEncoder().encode(value)
                guard data.count <= 64 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                succeeded = DesktopWidgetSnapshot.read(from: url) == value
                if !succeeded { message = "本机显示快照校验失败" }
            } catch { message = "原生小组件写入失败：" + error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false; self.error = message
                if succeeded {
                    self.previous = value; self.writes += 1
                    self.reloadWhenAllowed()
                }
                if let latest = self.pending { self.pending = nil; self.update(latest) }
            }
        }
    }
    private func reloadWhenAllowed() {
        let delay = 60 - Date().timeIntervalSince(lastReload)
        if delay <= 0 {
            delayedReload?.invalidate(); delayedReload = nil
            WidgetCenter.shared.reloadTimelines(ofKind: DesktopWidgetSnapshot.kind); lastReload = Date()
        } else if delayedReload == nil {
            // A final write within the throttle must still reach the widget even if content stops changing.
            delayedReload = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }; self.delayedReload = nil; self.reloadWhenAllowed()
            }
        }
    }
    var diagnostics: [String: Any] { ["enabled": enabled, "snapshotWrites": writes, "error": error ?? "", "dataSource": "own-read-only-display-snapshot", "sharedViaSandboxHelper": false, "mainAccessesSharedContainer": false, "systemControlsRefresh": true, "configurationCount": configurationCount ?? -1, "configurationQueryFailed": configurationError] }
}
