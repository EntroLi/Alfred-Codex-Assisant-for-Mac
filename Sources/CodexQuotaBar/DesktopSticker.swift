import AppKit
import SwiftUI

enum DesktopStickerPlacement {
    static func initial(in screen: CGRect) -> CGRect {
        let width = min(900, max(min(420, screen.width - 16), screen.width * 0.49))
        return fit(CGRect(x: screen.minX + screen.width * 0.26, y: screen.maxY - screen.height * 0.25 - width / 2, width: width, height: width / 2), in: screen)
    }
    static func fit(_ rect: CGRect, in screen: CGRect) -> CGRect {
        let width = min(max(1, rect.width), screen.width - 16, (screen.height - 16) * 2)
        return CGRect(x: min(max(rect.minX, screen.minX + 8), screen.maxX - width - 8),
                      y: min(max(rect.minY, screen.minY + 8), screen.maxY - width / 2 - 8), width: width, height: width / 2)
    }
}
private final class DesktopStickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class DesktopStickerGrip: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 12) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
struct DesktopStickerHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DesktopStickerGrip() }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.needsDisplay = true }
}

final class DesktopStickerController: NSObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private var panel: DesktopStickerPanel?
    private var host: NSHostingView<AnyView>?
    private var snapshot: DesktopWidgetSnapshot?
    private(set) var isVisible: Bool
    var onVisibilityChange: ((Bool) -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isVisible = defaults.object(forKey: "Alfred.desktopSticker.visible") as? Bool ?? true
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func update(_ value: DesktopWidgetSnapshot) {
        snapshot = value
        guard isVisible else { return }
        if panel == nil { makePanel() }
        if let size = panel?.frame.size {
            host?.rootView = AnyView(AlfredDesktopView(entry: AlfredDesktopEntry(date: Date(), snapshot: value)).desktopBody
                .frame(width: 500, height: 250).scaleEffect(size.width / 500).frame(width: size.width, height: size.height))
        }
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
    }
    func toggle() {
        isVisible.toggle(); defaults.set(isVisible, forKey: "Alfred.desktopSticker.visible")
        if isVisible, let snapshot { update(snapshot) } else { panel?.orderOut(nil); host?.rootView = AnyView(EmptyView()) }
        onVisibilityChange?(isVisible)
    }
    func resetPosition() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = DesktopStickerPlacement.initial(in: screen.frame)
        defaults.removeObject(forKey: "Alfred.desktopSticker.frame")
        panel?.setFrame(frame, display: true)
    }
    private func makePanel() {
        guard let screen = NSScreen.screens.first else { return }
        let saved = defaults.string(forKey: "Alfred.desktopSticker.frame").map(NSRectFromString).flatMap { rect -> CGRect? in
            rect.width.isFinite && rect.width > 0 && rect.height.isFinite && rect.height > 0 && rect.origin.x.isFinite && rect.origin.y.isFinite ? rect : nil
        }
        let target = saved.flatMap { rect in NSScreen.screens.first { $0.visibleFrame.intersects(rect) } } ?? screen
        let rect = saved.map { DesktopStickerPlacement.fit($0, in: target.visibleFrame) } ?? DesktopStickerPlacement.initial(in: screen.frame)
        let window = DesktopStickerPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Alfred · 蝙蝠洞桌贴"; window.setAccessibilityLabel(window.title)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.delegate = self
        let host = NSHostingView(rootView: AnyView(EmptyView())); host.frame = CGRect(origin: .zero, size: rect.size)
        host.autoresizingMask = [.width, .height]; window.contentView = host
        self.host = host; self.panel = window
    }
    func windowDidMove(_ notification: Notification) {
        if let panel { defaults.set(NSStringFromRect(panel.frame), forKey: "Alfred.desktopSticker.frame") }
    }
    @objc private func screensChanged() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let target = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) } ?? screen
        panel.setFrame(DesktopStickerPlacement.fit(panel.frame, in: target.visibleFrame), display: true)
    }
    func stop() { NotificationCenter.default.removeObserver(self); panel?.orderOut(nil) }
    var diagnostics: [String: Any] {
        ["visible": isVisible && panel?.isVisible == true, "nonactivating": true, "desktopLevel": true,
         "fullScreenAuxiliary": false, "frame": panel.map { NSStringFromRect($0.frame) } ?? "", "aspect": "4:2"]
    }
    func exportPreview(to url: URL) throws {
        guard let host else { throw CocoaError(.fileWriteUnknown) }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
