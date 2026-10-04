import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Alfred · 独立全屏验收宿主"
window.collectionBehavior = [.fullScreenPrimary]
window.backgroundColor = .windowBackgroundColor
let label = NSTextField(labelWithString: "Alfred 全屏浮层验收 · 不读取或修改其他应用")
label.frame = NSRect(x: 60, y: 300, width: 780, height: 40)
window.contentView!.addSubview(label)
let marker = CommandLine.arguments[1]
let observation = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
    try? Data("fullscreen-entered".utf8).write(to: URL(fileURLWithPath: marker))
}
window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.toggleFullScreen(nil) }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
app.run()
