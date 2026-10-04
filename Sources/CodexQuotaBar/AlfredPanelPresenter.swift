import AppKit

/// A transient detail surface, never a main app window. Nonactivation keeps the current full-screen Space.
final class AlfredDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class AlfredPanelPresenter {
    let window: AlfredDetailPanel
    private var outsideClick: Any?
    private var escapeKey: Any?
    private var spaceObserver: NSObjectProtocol?
    private weak var toggleAnchor: NSView?
    init(controller: NSViewController) {
        window = AlfredDetailPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Alfred"
        window.isReleasedWhenClosed = false; window.isFloatingPanel = true
        window.hidesOnDeactivate = false; window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 460, height: 560)
        window.contentMaxSize = NSSize(width: 460, height: 560)
        window.setContentSize(NSSize(width: 460, height: 560))
        controller.view.wantsLayer = true; controller.view.layer?.cornerRadius = 14
        controller.view.layer?.masksToBounds = true
    }
    var isShown: Bool { window.isVisible }
    func show(anchor: NSView?) {
        toggleAnchor = anchor
        let mouse = NSEvent.mouseLocation
        let screen = anchor?.window?.screen ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        let rect = anchor.flatMap { view in view.window?.convertToScreen(view.convert(view.bounds, to: nil)) }
        window.setFrameOrigin(Self.origin(anchor: rect, screen: screen.visibleFrame, size: window.frame.size))
        window.makeKeyAndOrderFront(nil) // nonactivatingPanel; deliberately no NSApp.activate.
        installDismissal()
    }
    func close() {
        window.orderOut(nil)
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }; outsideClick = nil
        if let escapeKey { NSEvent.removeMonitor(escapeKey) }; escapeKey = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }; spaceObserver = nil
    }
    private func installDismissal() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissForExternalClick(at: NSEvent.mouseLocation)
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.isShown == true { self?.close(); return nil }
            return event
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.close() }
    }
    func dismissForExternalClick(at point: NSPoint) {
        let anchor = toggleAnchor.flatMap { view in view.window?.convertToScreen(view.convert(view.bounds, to: nil)) }
        if Self.shouldDismiss(point: point, panel: window.frame, anchor: anchor) { close() }
    }
    static func shouldDismiss(point: NSPoint, panel: NSRect, anchor: NSRect?) -> Bool {
        // Menu-bar events can arrive via the global monitor before the status item's action.
        // Leave the anchor click to its toggle; otherwise it closes here and immediately reopens.
        !panel.contains(point) && !(anchor?.insetBy(dx: -2, dy: -2).contains(point) ?? false)
    }
    static func origin(anchor: NSRect?, screen: NSRect, size: NSSize) -> NSPoint {
        let center = anchor?.midX ?? screen.midX
        let top = min(anchor?.minY ?? screen.maxY, screen.maxY) - 4
        return NSPoint(x: max(screen.minX + 4, min(center - size.width / 2, screen.maxX - size.width - 4)),
                       y: max(screen.minY + 4, top - size.height))
    }
    deinit { close() }
}
