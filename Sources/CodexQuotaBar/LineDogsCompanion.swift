import AppKit
import Foundation

private struct LineDogDialogue: Codable {
    let kind: String
    let weight: Double
    let text: String
}

private struct LineDogIdleAction: Codable {
    let name: String
    let row: Int
    let frameCount: Int
    let duration: TimeInterval
    let weight: Double
    let visibleBounds: [Double]

    var sourceBounds: NSRect? {
        guard visibleBounds.count == 4 else { return nil }
        return NSRect(
            x: visibleBounds[0],
            y: visibleBounds[1],
            width: visibleBounds[2] - visibleBounds[0],
            height: visibleBounds[3] - visibleBounds[1]
        )
    }
}

private struct LineDogIdleChoice {
    let row: Int
    let frameCount: Int
    let duration: TimeInterval
    let bounds: NSRect
}

private final class LineDogsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class LineDogsBubbleView: NSView {
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    var text = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    func preferredSize(for text: String) -> NSSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .paragraphStyle: paragraph
        ]
        let natural = (text as NSString).boundingRect(
            with: NSSize(width: 1_000, height: 80),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let width = min(184, max(82, ceil(natural.width) + 24))
        let wrapped = (text as NSString).boundingRect(
            with: NSSize(width: width - 24, height: 160),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return NSSize(
            width: width,
            height: min(90, max(46, ceil(wrapped.height) + 32))
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !text.isEmpty else { return }

        let bubbleRect = NSRect(x: 2, y: 2, width: bounds.width - 4, height: bounds.height - 14)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bubbleRect.maxX - 34, y: bubbleRect.maxY - 1))
        tail.line(to: NSPoint(x: bubbleRect.maxX - 21, y: bounds.maxY - 2))
        tail.line(to: NSPoint(x: bubbleRect.maxX - 15, y: bubbleRect.maxY - 1))
        tail.close()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: bubbleRect, xRadius: 14, yRadius: 14).fill()
        tail.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0.12, alpha: 0.82).setStroke()
        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 14, yRadius: 14)
        outline.lineWidth = 1.6
        outline.stroke()
        tail.lineWidth = 1.6
        tail.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byCharWrapping
        text.draw(
            in: bubbleRect.insetBy(dx: 12, dy: 8),
            withAttributes: [
                .font: Self.font,
                .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
                .paragraphStyle: paragraph
            ]
        )
    }
}

private final class LineDogsPetView: NSView {
    private let bubbleView = LineDogsBubbleView(frame: NSRect(x: 8, y: 68, width: 140, height: 52))
    private let visiblePetBounds = NSRect(x: 90, y: 4, width: 132, height: 56)
    private var frameImage: NSImage?
    private var sourceVisibleBounds = NSRect(x: 0, y: 0, width: 192, height: 208)
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var didDrag = false

    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onMoveEnded: ((NSPoint) -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(bubbleView)
        bubbleView.alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setFrameImage(_ image: NSImage?, sourceVisibleBounds: NSRect) {
        frameImage = image
        self.sourceVisibleBounds = sourceVisibleBounds
        needsDisplay = true
    }

    func showBubble(_ text: String, duration: TimeInterval) {
        let bubbleSize = bubbleView.preferredSize(for: text)
        bubbleView.frame = NSRect(x: 8, y: 68, width: bubbleSize.width, height: bubbleSize.height)
        bubbleView.text = text
        bubbleView.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            bubbleView.animator().alphaValue = 1
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideBubble), object: nil)
        perform(#selector(hideBubble), with: nil, afterDelay: duration)
    }

    func clearBubble() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        bubbleView.alphaValue = 0
        bubbleView.isHidden = true
        bubbleView.text = ""
    }

    @objc func hideBubble() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.24
            bubbleView.animator().alphaValue = 0
        }, completionHandler: { [weak bubbleView] in
            bubbleView?.isHidden = true
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let frameImage else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        frameImage.draw(
            in: fittedFrameRect(for: frameImage.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func fittedFrameRect(for imageSize: NSSize) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0,
              sourceVisibleBounds.width > 0, sourceVisibleBounds.height > 0 else {
            return visiblePetBounds
        }
        let scale = min(
            visiblePetBounds.width / sourceVisibleBounds.width,
            visiblePetBounds.height / sourceVisibleBounds.height,
            1
        )
        return NSRect(
            x: visiblePetBounds.midX - sourceVisibleBounds.midX * scale,
            y: visiblePetBounds.minY - (imageSize.height - sourceVisibleBounds.maxY) * scale,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        let delta = NSPoint(x: location.x - dragStartMouse.x, y: location.y - dragStartMouse.y)
        if abs(delta.x) > 3 || abs(delta.y) > 3 {
            didDrag = true
        }
        window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + delta.x, y: dragStartOrigin.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            if let origin = window?.frame.origin {
                onMoveEnded?(origin)
            }
            return
        }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onSingleClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event, self)
    }
}

final class LineDogsCompanionController: NSObject {
    private enum Constants {
        static let atlasColumns = 8
        static let cellWidth = 192
        static let cellHeight = 208
        static let panelSize = NSSize(width: 230, height: 160)
        static let frameCounts = [7, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8]
        static let rowVisibleBounds = [
            NSRect(x: 5, y: 32, width: 182, height: 144),
            NSRect(x: 5, y: 30, width: 182, height: 148),
            NSRect(x: 5, y: 30, width: 182, height: 148),
            NSRect(x: 5, y: 34, width: 182, height: 139),
            NSRect(x: 5, y: 38, width: 182, height: 131),
            NSRect(x: 5, y: 37, width: 182, height: 134),
            NSRect(x: 5, y: 40, width: 182, height: 128),
            NSRect(x: 5, y: 33, width: 182, height: 157),
            NSRect(x: 5, y: 33, width: 182, height: 141),
            NSRect(x: 7, y: 35, width: 176, height: 139),
            NSRect(x: 13, y: 40, width: 165, height: 136)
        ]
        static let visibleKey = "lineDogsPetVisible"
        static let originXKey = "lineDogsPetOriginX"
        static let originYKey = "lineDogsPetOriginY"
    }

    private let panel: LineDogsPanel
    private let petView: LineDogsPetView
    private let defaults: UserDefaults
    private let dialogues: [LineDogDialogue]
    private let idleActions: [LineDogIdleAction]
    private var atlas: CGImage?
    private var frameCache: [Int: NSImage] = [:]
    private var frameCacheOrder: [Int] = []
    private var renderedFrameCount = 0
    private var patWorkItem: DispatchWorkItem?
    private var animationTimer: Timer?
    private var speechTimer: Timer?
    private var idleActionTimer: Timer?
    private var idleReturnTimer: Timer?
    private var activityTransitionWorkItem: DispatchWorkItem?
    private var hideBubbleWorkItem: DispatchWorkItem?
    private var currentRow = 0
    private var currentFrame = 0
    private var currentFrameCount = 7
    private var currentVisibleBounds = Constants.rowVisibleBounds[0]
    private var currentActivity = CodexActivityKind.idle
    private var recentLines: [String] = []
    private var mutedUntil: Date?
    private var isPatting = false
    private var lastIdleRow = 0
    private var idleActionQueue: [LineDogIdleChoice] = []

    var onOpenCodex: (() -> Void)?
    var isVisible: Bool { panel.isVisible && defaults.bool(forKey: Constants.visibleKey) }

    var diagnostics: [String: Any] {
        ["visible": isVisible, "animationRunning": animationTimer != nil,
         "idleRunning": idleActionTimer != nil || idleReturnTimer != nil,
         "speechRunning": speechTimer != nil, "renderedFrames": renderedFrameCount,
         "cachedFrames": frameCache.count, "atlasDecoded": atlas != nil]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dialogues = Self.loadDialogues()
        idleActions = Self.loadIdleActions()
        petView = LineDogsPetView(frame: NSRect(origin: .zero, size: Constants.panelSize))
        panel = LineDogsPanel(
            contentRect: NSRect(origin: .zero, size: Constants.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.title = "线条小狗"
        panel.setAccessibilityLabel("线条小狗桌宠")
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false
        panel.contentView = petView
        petView.setAccessibilityLabel("可拖动的线条小狗；单击摸摸，双击打开 Codex")

        petView.onSingleClick = { [weak self] in self?.pat() }
        petView.onDoubleClick = { [weak self] in
            guard let self else { return }
            if let onOpenCodex {
                say("要一起开始一个新任务吗？我把 Codex 叫过来啦。")
                onOpenCodex()
            } else {
                speakNow()
            }
        }
        petView.onMoveEnded = { [weak self] origin in
            self?.save(origin: origin)
        }
        petView.onContextMenu = { [weak self] event, view in
            self?.showContextMenu(event: event, view: view)
        }

        restorePosition()
        if defaults.object(forKey: Constants.visibleKey) == nil {
            defaults.set(true, forKey: Constants.visibleKey)
        }
        if defaults.bool(forKey: Constants.visibleKey) {
            show()
        }
    }

    func update(activity: CodexActivitySnapshot) {
        guard isVisible else {
            activityTransitionWorkItem?.cancel()
            activityTransitionWorkItem = nil
            currentActivity = activity.kind
            return
        }
        if activity.kind == .idle, currentActivity != .idle {
            guard activityTransitionWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                activityTransitionWorkItem = nil
                transitionActivity(to: .idle)
            }
            activityTransitionWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
            return
        }
        activityTransitionWorkItem?.cancel()
        activityTransitionWorkItem = nil
        transitionActivity(to: activity.kind)
    }

    func toggleVisibility() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        clampToVisibleScreen()
        panel.orderFrontRegardless()
        defaults.set(true, forKey: Constants.visibleKey)
        applyAnimationForCurrentActivity()
        startAnimation()
        scheduleSpeech(first: true)
    }

    func hide() {
        panel.orderOut(nil)
        defaults.set(false, forKey: Constants.visibleKey)
        shutdown()
        isPatting = false
        petView.clearBubble()
        petView.setFrameImage(nil, sourceVisibleBounds: currentVisibleBounds)
        frameCache.removeAll()
        frameCacheOrder.removeAll()
        atlas = nil
    }

    func speakNow() {
        if isWaiting(currentActivity) {
            sayRandom(kinds: ["waiting"])
        } else if isWorking(currentActivity) {
            sayRandom(kinds: ["work"])
        } else {
            sayRandom(kinds: ambientKinds())
        }
    }

    func shutdown() {
        animationTimer?.invalidate()
        speechTimer?.invalidate()
        idleActionTimer?.invalidate()
        idleReturnTimer?.invalidate()
        activityTransitionWorkItem?.cancel()
        hideBubbleWorkItem?.cancel()
        patWorkItem?.cancel()
        animationTimer = nil
        speechTimer = nil
        idleActionTimer = nil
        idleReturnTimer = nil
        activityTransitionWorkItem = nil
        patWorkItem = nil
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        guard isVisible else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: true) { [weak self] _ in
            guard let self, isVisible else { return }
            currentFrame = (currentFrame + 1) % currentFrameCount
            displayCurrentFrame()
        }
        displayCurrentFrame()
    }

    private func transitionActivity(to kind: CodexActivityKind) {
        let previous = currentActivity
        guard previous != kind else { return }
        currentActivity = kind
        applyAnimationForCurrentActivity()

        if previous != .idle, kind == .idle {
            sayRandom(kinds: ["success"])
        } else if isWaiting(kind), !isWaiting(previous) {
            sayRandom(kinds: ["waiting"])
        } else if !isWorking(previous), isWorking(kind) {
            sayRandom(kinds: ["work"])
        }
    }

    private func applyAnimationForCurrentActivity() {
        guard isVisible, !isPatting else { return }
        cancelIdleAnimation()
        if isWaiting(currentActivity) {
            setAnimation(row: 6)
        } else if isWorking(currentActivity) {
            setAnimation(row: 7)
        } else {
            setAnimation(row: 0)
            scheduleIdleAction(initial: true)
        }
    }

    private func setAnimation(row: Int) {
        setAnimation(
            row: row,
            frameCount: Constants.frameCounts[row],
            visibleBounds: Constants.rowVisibleBounds[row]
        )
    }

    private func setAnimation(row: Int, frameCount: Int, visibleBounds: NSRect) {
        guard currentRow != row
                || currentFrameCount != frameCount
                || currentVisibleBounds != visibleBounds else {
            displayCurrentFrame()
            return
        }
        currentRow = row
        currentFrameCount = frameCount
        currentVisibleBounds = visibleBounds
        currentFrame = 0
        displayCurrentFrame()
    }

    private func displayCurrentFrame() {
        guard isVisible else { return }
        renderedFrameCount += 1
        petView.setFrameImage(
            frameImage(row: currentRow, column: currentFrame),
            sourceVisibleBounds: currentVisibleBounds
        )
    }

    private func scheduleIdleAction(initial: Bool) {
        scheduleIdleAction(
            after: initial
                ? Double.random(in: 1.5...3.5)
                : Double.random(in: 0.45...1.1)
        )
    }

    private func scheduleIdleAction(after delay: TimeInterval) {
        idleActionTimer?.invalidate()
        guard isVisible, currentActivity == .idle, !isPatting else { return }
        idleActionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.playRandomIdleAction()
        }
    }

    private func playRandomIdleAction() {
        guard isVisible, currentActivity == .idle, !isPatting else { return }
        if idleActionQueue.isEmpty {
            refillIdleActionQueue()
        }
        guard !idleActionQueue.isEmpty else { return }
        let selected = idleActionQueue.removeFirst()
        lastIdleRow = selected.row
        setAnimation(
            row: selected.row,
            frameCount: selected.frameCount,
            visibleBounds: selected.bounds
        )
        idleReturnTimer?.invalidate()
        idleReturnTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, isVisible, currentActivity == .idle, !isPatting else { return }
            playRandomIdleAction()
        }
    }

    private func refillIdleActionQueue() {
        let standardActions: [LineDogIdleChoice] = [
            LineDogIdleChoice(row: 1, frameCount: Constants.frameCounts[1], duration: 2.6, bounds: Constants.rowVisibleBounds[1]),
            LineDogIdleChoice(row: 2, frameCount: Constants.frameCounts[2], duration: 2.6, bounds: Constants.rowVisibleBounds[2]),
            LineDogIdleChoice(row: 3, frameCount: Constants.frameCounts[3], duration: 2.2, bounds: Constants.rowVisibleBounds[3]),
            LineDogIdleChoice(row: 4, frameCount: Constants.frameCounts[4], duration: 2.4, bounds: Constants.rowVisibleBounds[4]),
            LineDogIdleChoice(row: 5, frameCount: Constants.frameCounts[5], duration: 4.8, bounds: Constants.rowVisibleBounds[5]),
            LineDogIdleChoice(row: 8, frameCount: Constants.frameCounts[8], duration: 3.4, bounds: Constants.rowVisibleBounds[8])
        ]
        let officialActions = idleActions.compactMap { action
                -> LineDogIdleChoice? in
            guard action.weight > 0, let bounds = action.sourceBounds else { return nil }
            return LineDogIdleChoice(
                row: action.row,
                frameCount: action.frameCount,
                duration: action.duration,
                bounds: bounds
            )
        }
        var queue = (standardActions + officialActions).shuffled()
        if queue.count > 1, queue.first?.row == lastIdleRow {
            queue.swapAt(0, 1)
        }
        idleActionQueue = queue
    }

    private func cancelIdleAnimation() {
        idleActionTimer?.invalidate()
        idleReturnTimer?.invalidate()
        idleActionTimer = nil
        idleReturnTimer = nil
    }

    private func frameImage(row: Int, column: Int) -> NSImage? {
        guard isVisible, row >= 0, column >= 0, column < Constants.atlasColumns else { return nil }
        let key = row * Constants.atlasColumns + column
        if let image = frameCache[key] {
            frameCacheOrder.removeAll { $0 == key }
            frameCacheOrder.append(key)
            return image
        }
        if atlas == nil { atlas = Self.loadAtlas() }
        guard let atlas else { return nil }
        let rect = CGRect(x: column * Constants.cellWidth, y: row * Constants.cellHeight,
                          width: Constants.cellWidth, height: Constants.cellHeight)
        guard rect.maxY <= CGFloat(atlas.height), let cropped = atlas.cropping(to: rect),
              let decoded = Self.decodedBitmap(cropped) else { return nil }
        let image = NSImage(cgImage: decoded, size: NSSize(width: Constants.cellWidth, height: Constants.cellHeight))
        frameCache[key] = image
        frameCacheOrder.append(key)
        // 48 RGBA cells occupy at most 7.4 MiB; the decoded atlas is capped at 64 MiB.
        while frameCacheOrder.count > 48 { frameCache.removeValue(forKey: frameCacheOrder.removeFirst()) }
        return image
    }

    private static func decodedBitmap(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              image.width * image.height * 4 <= 64 * 1024 * 1024,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private func pat() {
        guard isVisible, !isPatting else { return }
        isPatting = true
        cancelIdleAnimation()
        sayRandom(kinds: ["pat"])
        setAnimation(row: 3)
        let item = DispatchWorkItem { [weak self] in
            guard let self, isVisible else { return }
            patWorkItem = nil
            isPatting = false
            applyAnimationForCurrentActivity()
        }
        patWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: item)
    }

    private func scheduleSpeech(first: Bool) {
        speechTimer?.invalidate()
        guard isVisible else { return }
        let delay = 180.0
        speechTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if panel.isVisible, !isMuted {
                speakNow()
            }
            scheduleSpeech(first: false)
        }
    }

    private var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    private func ambientKinds() -> [String] {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 23 || hour < 7 {
            return ["night"]
        }
        if hour >= 7, hour < 11 {
            return ["morning", "companion", "duo"]
        }
        return ["companion", "duo", "break", "longIdle"]
    }

    private func sayRandom(kinds: [String]) {
        guard isVisible, !isMuted else { return }
        let pool = dialogues.filter { kinds.contains($0.kind) }
        guard !pool.isEmpty else { return }
        let unused = pool.filter { !recentLines.contains($0.text) }
        let candidates = unused.isEmpty ? pool : unused
        let total = candidates.reduce(0) { $0 + max(0.1, $1.weight) }
        var pick = Double.random(in: 0..<total)
        let selected = candidates.first { item in
            pick -= max(0.1, item.weight)
            return pick <= 0
        } ?? candidates[0]
        recentLines.append(selected.text)
        recentLines = Array(recentLines.suffix(10))
        say(selected.text)
    }

    private func say(_ text: String) {
        guard panel.isVisible, defaults.bool(forKey: Constants.visibleKey) else { return }
        petView.showBubble(text, duration: 30)
    }

    private func showContextMenu(event: NSEvent, view: NSView) {
        let menu = NSMenu()
        let speak = NSMenuItem(title: "说句话", action: #selector(speakFromMenu), keyEquivalent: "")
        let mute = NSMenuItem(title: isMuted ? "恢复随机说话" : "安静一小时", action: #selector(toggleMute), keyEquivalent: "")
        let hide = NSMenuItem(title: "隐藏线条小狗", action: #selector(hideFromMenu), keyEquivalent: "")
        for item in [speak, mute, hide] {
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func speakFromMenu() { speakNow() }

    @objc private func toggleMute() {
        if isMuted {
            mutedUntil = nil
            say("我们回来啦，会尽量小声一点。")
        } else {
            mutedUntil = Date().addingTimeInterval(3600)
            petView.hideBubble()
        }
    }

    @objc private func hideFromMenu() { hide() }

    private func restorePosition() {
        if defaults.object(forKey: Constants.originXKey) != nil,
           defaults.object(forKey: Constants.originYKey) != nil {
            panel.setFrameOrigin(NSPoint(
                x: defaults.double(forKey: Constants.originXKey),
                y: defaults.double(forKey: Constants.originYKey)
            ))
            clampToVisibleScreen()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - Constants.panelSize.width - 24,
            y: visible.minY + 16
        ))
    }

    private func save(origin: NSPoint) {
        clampToVisibleScreen()
        let finalOrigin = panel.frame.origin
        defaults.set(finalOrigin.x, forKey: Constants.originXKey)
        defaults.set(finalOrigin.y, forKey: Constants.originYKey)
    }

    private func clampToVisibleScreen() {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(panel.frame.origin.x, visible.minX - 80), visible.maxX - 100)
        let y = min(max(panel.frame.origin.y, visible.minY), visible.maxY - 90)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func isWorking(_ kind: CodexActivityKind) -> Bool {
        switch kind {
        case .thinking, .tool, .editing, .command:
            return true
        default:
            return false
        }
    }

    private func isWaiting(_ kind: CodexActivityKind) -> Bool {
        switch kind {
        case .waitingQuestion, .waitingReview, .waitingApproval:
            return true
        default:
            return false
        }
    }

    private static func loadDialogues() -> [LineDogDialogue] {
        guard let url = Bundle.main.url(forResource: "line-dogs-dialogues", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([LineDogDialogue].self, from: data) else {
            return []
        }
        return entries
    }

    private static func loadIdleActions() -> [LineDogIdleAction] {
        guard let url = Bundle.main.url(forResource: "line-dogs-idle-actions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([LineDogIdleAction].self, from: data) else {
            return []
        }
        return entries
    }

    private static func loadAtlas() -> CGImage? {
        guard let url = Bundle.main.url(forResource: "line-dogs-companion", withExtension: "webp"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let raw = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return decodedBitmap(raw)
    }
}
