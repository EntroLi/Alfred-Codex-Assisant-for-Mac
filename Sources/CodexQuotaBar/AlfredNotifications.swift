import Foundation
import UserNotifications

enum AlfredNotificationStory: String, CaseIterable {
    case attention, quota, rest, agenda, mission, voice, test
    init(kind: String) {
        switch kind {
        case "attention": self = .attention
        case "quota": self = .quota
        case "break": self = .rest
        case "calendar": self = .agenda
        case "todo": self = .mission
        case "voice": self = .voice
        default: self = .test
        }
    }
    var subtitle: String {
        switch self {
        case .attention: return "BAT-SIGNAL · 蝙蝠信号"
        case .quota: return "WAYNE RESERVE · 韦恩储备"
        case .rest: return "BATCAVE · 蝙蝠洞整备"
        case .agenda: return "GOTHAM SCHEDULE · 哥谭日程"
        case .mission: return "MISSION BRIEF · 优先任务"
        case .voice: return "DOT CALL · 管家语音"
        case .test: return "ALFRED · 通讯检查"
        }
    }
    var artworkName: String {
        switch self {
        case .quota: return "notification-reserve"
        case .rest: return "notification-batcave"
        default: return "notification-signal"
        }
    }
}

struct PreparedAlfredNotification {
    let content: UNMutableNotificationContent
    let attachmentError: String?
    let temporaryDirectory: URL?
    // A unique copy is kept until the system finishes accepting the request.
    // Never hand the notification service a packaged resource it could move.
    func cleanup() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

enum AlfredNotifications {
    static let testTitle = "少爷，蝙蝠信号已点亮"
    static let testBody = "Alfred 通讯检查：蝙蝠洞在线，提醒通道已就绪。这是一条测试通知。"
    static func prepare(title: String, body: String, kind: String, category: String, noticeID: String,
                        resourceDirectory: URL? = Bundle.main.resourceURL,
                        includeArtwork: Bool = false) -> PreparedAlfredNotification {
        let story = AlfredNotificationStory(kind: kind)
        let content = UNMutableNotificationContent()
        content.title = title; content.subtitle = story.subtitle; content.body = bannerBody(body, kind: kind)
        content.categoryIdentifier = category; content.threadIdentifier = "alfred-" + kind
        content.sound = .default
        content.userInfo = ["noticeID": noticeID, "alfredThemeVersion": 2]
        // The system puts our app icon on the left. A duplicate image attachment
        // uses the right-hand content space, making the task and action truncate.
        guard includeArtwork else {
            return PreparedAlfredNotification(content: content, attachmentError: nil, temporaryDirectory: nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Alfred-notification-" + UUID().uuidString, isDirectory: true)
        do {
            guard let source = resourceDirectory?.appendingPathComponent(story.artworkName + ".png"),
                  FileManager.default.fileExists(atPath: source.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let copy = directory.appendingPathComponent(story.artworkName + ".png")
            try FileManager.default.copyItem(at: source, to: copy)
            content.attachments = [try UNNotificationAttachment(identifier: "alfred-bat-artwork", url: copy,
                options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false])]
            return PreparedAlfredNotification(content: content, attachmentError: nil, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            // Artwork failure must never suppress a useful textual reminder.
            return PreparedAlfredNotification(content: content, attachmentError: error.localizedDescription, temporaryDirectory: nil)
        }
    }

    static func bannerBody(_ body: String, kind: String) -> String {
        let prefix = "蝙蝠信号已亮："
        let suffix = "\n请返回对话处理。此信号会保留至你确认已读。"
        // Only compact our own known template; arbitrary reminder text stays intact.
        guard kind == "attention", body.hasPrefix(prefix), body.hasSuffix(suffix) else { return body }
        let task = body.dropFirst(prefix.count).dropLast(suffix.count)
            .replacingOccurrences(of: "\n", with: " ")
        let name = task.count > 40 ? String(task.prefix(39)) + "…" : task
        return name + "\n请返回对话处理，信号保留至已读。"
    }
}
