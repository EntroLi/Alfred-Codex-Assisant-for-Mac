import Foundation

struct LocalDailyBrief {
    let summary: String
    let todos: String
    static func make(analytics: UsageAnalyticsSnapshot, activities: [CodexActivitySnapshot], agenda: MacAgendaSnapshot,
                     activeSeconds: TimeInterval, breaks: Int, now: Date = Date(), calendar: Calendar = .current) -> Self {
        let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN"); date.timeZone = calendar.timeZone
        date.dateFormat = "M月d日 HH:mm"; let stamp = date.string(from: now)
        let start = calendar.startOfDay(for: now), end = calendar.date(byAdding: .day, value: 1, to: start)!
        let top = analytics.dailyBuckets.first { calendar.isDate($0.date, inSameDayAs: now) }?.topConversations.prefix(3) ?? []
        let topText = top.map { "· \($0.title)（\(DailyBrief.formatTokens($0.tokens.total)) token）" }.joined(separator: "\n")
        let recent = analytics.recentTasks.filter { ($0.completedAt ?? $0.startedAt) >= start && ($0.completedAt ?? $0.startedAt) < end }.prefix(5)
        date.dateFormat = "HH:mm"
        let records = recent.map { "· \(date.string(from: $0.completedAt ?? $0.startedAt)) \($0.title) · \($0.completedAt == nil ? "未见结束记录" : "回合已结束")" }.joined(separator: "\n")
        let meetings = agenda.meetings.filter { !$0.cancelled && $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
        func meetingLine(_ event: AgendaMeeting) -> String {
            if event.allDay { return "· 全天 · " + event.title }
            let state = event.end <= now ? "时段已过" : event.start <= now ? "当前时段" : "待开始"
            return "· \(date.string(from: event.start))–\(date.string(from: event.end)) \(event.title)（\(state)）"
        }
        let calendarText = agenda.eventsAccess == .allowed ? (meetings.isEmpty ? (agenda.error == nil ? "已读取的日历中没有今日日程。" : "日程读取异常，今日日程暂无法确认。") : meetings.prefix(6).map(meetingLine).joined(separator: "\n")) : "日历\(agenda.eventsAccess.label)，今日日程暂无法确认。"
        var signals: [CodexActivitySnapshot] = [], seen = Set<String>()
        for activity in activities.sorted(by: { $0.kind.priority == $1.kind.priority ? $0.updatedAt > $1.updatedAt : $0.kind.priority > $1.kind.priority }) where activity.kind.priority >= 90 {
            if seen.insert(activity.sessionID ?? activity.sessionName ?? activity.kind.label).inserted { signals.append(activity) }
        }
        let signalText = signals.prefix(5).map { "☐ \($0.displayText)" }.joined(separator: "\n")
        let reminders = orderedTodos(agenda.todos, now: now, calendar: calendar)
        date.dateFormat = "M/d HH:mm"
        let reminderText = reminders.prefix(6).map { todo -> String in
            var timing = "无截止日期"
            if let due = todo.due {
                date.dateFormat = todo.dueHasTime ? "M/d HH:mm" : "M/d"
                let overdue = todo.dueHasTime ? due < now : calendar.startOfDay(for: due) < start
                timing = (overdue ? "已逾期 · " : calendar.isDate(due, inSameDayAs: now) ? "今天截止 · " : "截止 ") + date.string(from: due)
            }
            return "☐ \(todo.title)（\(timing)\(todo.priority > 0 ? " · 优先级 \(todo.priority)" : "")）"
        }.joined(separator: "\n")
        let pendingMeetings = meetings.filter { $0.end > now }
        date.dateFormat = "HH:mm"
        var actions = ["\(stamp) · 哥谭今日行动清单", "少爷，先回应蝙蝠信号，再准备今天的日程与优先任务。"]
        actions.append("蝙蝠信号 · 需要你处理\n" + (signalText.isEmpty ? "本机当前没有待答复、待审阅或待放行信号。" : signalText))
        actions.append("哥谭日程 · 接下来\n" + (agenda.eventsAccess != .allowed ? "日历\(agenda.eventsAccess.label)，暂无法确认。" : pendingMeetings.isEmpty ? (agenda.error == nil ? "已读取的日历中没有今天尚未结束的日程。" : "日程读取异常，接下来的日程暂无法确认。") : pendingMeetings.prefix(6).map(meetingLine).joined(separator: "\n")))
        if pendingMeetings.isEmpty, let next = agenda.selection.nextMeeting, next.start >= end {
            date.dateFormat = "M/d HH:mm"; actions.append("下一次出场 · \(date.string(from: next.start)) \(next.title)")
        }
        actions.append("优先任务 · 提醒事项\n" + (agenda.remindersAccess != .allowed ? "提醒事项\(agenda.remindersAccess.label)，暂无法确认。" : reminderText.isEmpty ? (agenda.error == nil ? "已读取的提醒中暂无今天到期、逾期或高优先级任务。" : "提醒读取异常，优先任务暂无法确认。") : reminderText))
        let health = agenda.error.map { "读取异常：\($0)；显示的是已有结果，可能过期或不完整，请重新读取。" } ?? "日程与提醒只读，勾选和改期请在系统应用中处理。"
        date.dateFormat = "M/d HH:mm"
        let source = "依据：本机Codex记录、Mac日历和未完成提醒。\n日历/提醒读取 \(agenda.fetchedAt.map { date.string(from: $0) } ?? "尚未读取") · Codex用量读取 \(date.string(from: analytics.generatedAt))\n" + health
        actions.append(source)
        let reserve = "韦恩装备记录\n本机用量 \(DailyBrief.formatTokens(analytics.today.tokens.total)) token；输入活跃约 \(max(0, Int(activeSeconds / 60))) 分钟，已确认活动 \(breaks) 次。"
        let opening = top.isEmpty ? "少爷，今天尚无可确认的本机Codex用量记录。" : "少爷，今天的本机行动主要投入以下对话：\n" + topText
        let summary = ["\(stamp) · 蝙蝠洞日报", opening, "行动日志 · 最近记录\n" + (records.isEmpty ? "今日最近记录中暂无回合。" : records) + "\n回合结束也可能是中断，不代表整个项目完成。", "哥谭日程 · 今日记录\n" + calendarText + "\n时段经过不等于实际出席。", reserve, signals.isEmpty ? "蝙蝠信号暂静；下一步按今日行动清单推进。" : "仍有 \(signals.count) 个本机信号需要你处理，详见今日行动清单。", source].joined(separator: "\n\n")
        return Self(summary: summary, todos: actions.joined(separator: "\n\n"))
    }
    static func orderedTodos(_ todos: [AgendaTodo], now: Date, calendar: Calendar) -> [AgendaTodo] {
        let start = calendar.startOfDay(for: now), end = calendar.date(byAdding: .day, value: 1, to: start)!
        func rank(_ todo: AgendaTodo) -> Int {
            guard let due = todo.due else { return 2 }
            if todo.dueHasTime ? due < now : calendar.startOfDay(for: due) < start { return 0 }
            return due < end ? 1 : 2
        }
        return todos.filter { !$0.completed && (($0.due.map { $0 < end } ?? false) || (1...4).contains($0.priority)) }.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            let a = $0.priority > 0 ? $0.priority : Int.max, b = $1.priority > 0 ? $1.priority : Int.max
            if a != b { return a < b }
            if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            return $0.id < $1.id
        }
    }
}
