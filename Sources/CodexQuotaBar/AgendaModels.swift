import Foundation

struct AgendaMeeting: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    var allDay = false
    var cancelled = false
}
struct AgendaTodo: Equatable {
    let id: String
    let title: String
    let priority: Int
    let due: Date?
    var completed = false
    var dueHasTime = true
}
struct AgendaSelection: Equatable {
    var nextMeeting: AgendaMeeting?
    var priorityTodo: AgendaTodo?
    var status: String
    var description: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M/d E HH:mm"
        let meeting = nextMeeting.map { "下一场 · \(formatter.string(from: $0.start))\n\($0.title)" } ?? "下一场 · 暂无近期定时日程"
        let todo = priorityTodo.map { "优先待办 · \($0.title)" + ($0.due.map { "\n截止 \(formatter.string(from: $0))" } ?? "") } ?? "优先待办 · 暂无未完成事项"
        return meeting + "\n\n" + todo + "\n" + status
    }
    static func select(meetings: [AgendaMeeting], todos: [AgendaTodo], now: Date, status: String) -> AgendaSelection {
        let next = meetings.filter { !$0.allDay && !$0.cancelled && $0.start >= now }.min { $0.start < $1.start }
        let todo = todos.filter { !$0.completed }.min { a, b in
            let ap = a.priority > 0 ? a.priority : Int.max, bp = b.priority > 0 ? b.priority : Int.max
            if ap != bp { return ap < bp }
            if a.due != b.due { return (a.due ?? .distantFuture) < (b.due ?? .distantFuture) }
            return a.id < b.id
        }
        return AgendaSelection(nextMeeting: next, priorityTodo: todo, status: status)
    }
}
