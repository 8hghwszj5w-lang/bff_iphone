import EventKit
import Foundation

// MARK: - 本机信息工具：日历读取/创建、提醒事项读取/创建、备忘录搜索
//
// 这些是"访问用户本机数据"的常驻工具（同日程工具，不受联网开关控制）。
// 权限首次调用时弹系统授权框；拒绝时返回带设置路径的指引文案，
// 模型会把指引转告用户。时间参数约定：
//   · "HH:MM" → 今天该时刻；完整 "yyyy-MM-dd HH:MM" → 指定那天
//   · 缺省 end = start + 1 小时（日历）

// MARK: 时间参数解析（纯函数，可单测）

enum DeviceToolDateParser {
    /// 解析工具参数里的时间。"HH:MM" 按基准日的当天；"yyyy-MM-dd HH:MM" 按完整日期。
    static func parse(_ value: String, baseDay: Date = Date()) -> Date? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = DateFormatter()
        full.dateFormat = "yyyy-MM-dd HH:mm"
        full.locale = Locale(identifier: "en_US_POSIX")
        full.timeZone = .current
        if let date = full.date(from: v) { return date }

        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.timeZone = .current
        guard let time = hm.date(from: v) else { return nil }
        let cal = Calendar.current
        var dayComponents = cal.dateComponents([.year, .month, .day], from: baseDay)
        let timeComponents = cal.dateComponents([.hour, .minute], from: time)
        dayComponents.hour = timeComponents.hour
        dayComponents.minute = timeComponents.minute
        return cal.date(from: dayComponents)
    }
}

/// 事件/提醒的展示格式化（纯函数，可单测）
enum DeviceToolFormatter {
    static func rangeLabel(start: Date, end: Date) -> String {
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        hm.locale = Locale(identifier: "en_US_POSIX")
        return "\(hm.string(from: start))–\(hm.string(from: end))"
    }

    static func eventsText(_ events: [EKEvent]) -> String {
        guard !events.isEmpty else { return "那天日历上是空的。" }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        hm.locale = Locale(identifier: "en_US_POSIX")
        return events.map { event in
            var line = "\(hm.string(from: event.startDate))–\(hm.string(from: event.endDate)) \(event.title ?? "(无标题)")"
            if let location = event.location, !location.isEmpty { line += "（\(location)）" }
            return line
        }.joined(separator: "\n")
    }

    static func remindersText(_ reminders: [EKReminder]) -> String {
        guard !reminders.isEmpty else { return "没有未完成的提醒事项。" }
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return reminders.map { reminder -> String in
            var line = "· \(reminder.title ?? "(无标题)")"
            if let due = reminder.dueDateComponents?.date {
                line += "（到期：\(f.string(from: due))）"
            }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: 日历读取

struct CalendarReadTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "calendar_read",
            description: "查看用户手机日历上某天有哪些日程安排（跨 App 的真实日历，不是你自己的生活日程）。用户问「我今天有什么会」「明天忙不忙」时用。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "day": .object([
                        "type": .string("string"),
                        "enum": .array([.string("today"), .string("tomorrow"), .string("yesterday")]),
                        "description": .string("看哪一天，默认今天。"),
                    ])
                ]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        let dayName = (try? JSONDecoder().decode(DayArg.self, from: Data(argumentsJSON.utf8)))?.day ?? "today"
        guard let date = await ScheduleStore.dayKey(for: dayName)?.toDate() else {
            return "{\"error\": \"day 只能是 today / tomorrow / yesterday\"}"
        }
        if let denial = await bridge.requestCalendarAccess() { return denial }
        do {
            let events = try bridge.events(on: date)
            return DeviceToolFormatter.eventsText(events)
        } catch {
            return "日历读取失败：\(error.localizedDescription)"
        }
    }
}

private struct DayArg: Decodable { let day: String }

// MARK: 日历创建

struct CalendarCreateTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "calendar_create",
            description: "在用户手机日历上新建一个日程事件。用户说「帮我记一下周三下午三点开会」这类请求时用。title 必填；start 必填（HH:MM 表示今天，或 yyyy-MM-dd HH:MM）；end 缺省 = start + 1 小时。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("事件标题")]),
                    "start": .object(["type": .string("string"), "description": .string("开始时间：HH:MM（今天）或 yyyy-MM-dd HH:MM")]),
                    "end": .object(["type": .string("string"), "description": .string("结束时间，格式同 start；缺省 = 开始 + 1 小时")]),
                    "location": .object(["type": .string("string"), "description": .string("地点（可选）")]),
                ]),
                "required": .array([.string("title"), .string("start")]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        guard let args = try? JSONDecoder().decode(CreateArgs.self, from: Data(argumentsJSON.utf8)) else {
            return "{\"error\": \"参数需要 JSON：title 必填，start 必填\"}"
        }
        if let denial = await bridge.requestCalendarAccess() { return denial }
        guard let start = DeviceToolDateParser.parse(args.start) else {
            return "时间没看懂：\(args.start)。请用 HH:MM 或 yyyy-MM-dd HH:MM 格式。"
        }
        let end = args.end.flatMap { DeviceToolDateParser.parse($0, baseDay: start) }
            ?? start.addingTimeInterval(3600)
        do {
            _ = try bridge.createEvent(title: args.title, startDate: start, endDate: end,
                                       location: args.location?.isEmpty == true ? nil : args.location)
            return "已写入日历：\(DeviceToolFormatter.rangeLabel(start: start, end: end)) \(args.title)。回复里用自己的口吻确认即可。"
        } catch {
            return "写入日历失败：\(error.localizedDescription)"
        }
    }

    private struct CreateArgs: Decodable {
        let title: String
        let start: String
        let end: String?
        let location: String?
    }
}

// MARK: 提醒事项

struct RemindersReadTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "reminders_read",
            description: "查看用户手机「提醒事项」App 里未完成的提醒。用户问「我有什么待办」「提醒事项还有啥没做」时用。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        if let denial = await bridge.requestRemindersAccess() { return denial }
        do {
            return DeviceToolFormatter.remindersText(try await bridge.pendingReminders())
        } catch {
            return "提醒事项读取失败：\(error.localizedDescription)"
        }
    }
}

struct RemindersCreateTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "reminders_create",
            description: "在用户手机「提醒事项」App 里新建一条提醒。用户说「提醒我明天上午买牛奶」这类请求时用。due 可选（HH:MM 表示今天，或 yyyy-MM-dd HH:MM）。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("提醒内容")]),
                    "due": .object(["type": .string("string"), "description": .string("到期时间（可选）：HH:MM（今天）或 yyyy-MM-dd HH:MM")]),
                ]),
                "required": .array([.string("title")]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        guard let args = try? JSONDecoder().decode(CreateArgs.self, from: Data(argumentsJSON.utf8)) else {
            return "{\"error\": \"参数需要 JSON：title 必填\"}"
        }
        if let denial = await bridge.requestRemindersAccess() { return denial }
        let due = args.due.flatMap { DeviceToolDateParser.parse($0) }
        do {
            _ = try bridge.createReminder(title: args.title, due: due)
            return "已加入提醒事项：\(args.title)。回复里用自己的口吻确认即可。"
        } catch {
            return "写入提醒事项失败：\(error.localizedDescription)"
        }
    }

    private struct CreateArgs: Decodable { let title: String; let due: String? }
}

// MARK: 备忘录搜索（只读标题/摘要，见 NotesBridge 顶部说明）

struct NotesSearchTool: AgentTool {
    let bridge = SpotlightNotesBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "notes_search",
            description: "按关键词搜用户手机「备忘录」App 里的笔记。注意：受系统能力限制只能拿到标题和摘要片段，读不到全文；系统没收录（新记的、被锁的）就搜不到。用户问「我备忘录里有没有…」时用，找不到要如实说。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("关键词；留空 = 最近使用的前几条")]),
                ]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        let query = (try? JSONDecoder().decode(QueryArgs.self, from: Data(argumentsJSON.utf8)))?.query ?? ""
        do {
            let hits = try await bridge.search(query)
            guard !hits.isEmpty else {
                return "备忘录里没搜到相关内容（备忘录只能按标题/摘要检索，全文与新建需要用户在系统 App 里操作）。"
            }
            let f = DateFormatter()
            f.dateFormat = "M/d"
            f.locale = Locale(identifier: "en_US_POSIX")
            return hits.enumerated().map { index, hit -> String in
                var line = "\(index + 1). \(hit.title)"
                if !hit.snippet.isEmpty { line += "：\(hit.snippet.prefix(80))" }
                if let last = hit.lastUsed { line += "（\(f.string(from: last))）" }
                return line
            }.joined(separator: "\n")
        } catch {
            return "备忘录搜索失败：\(error.localizedDescription)"
        }
    }

    private struct QueryArgs: Decodable { let query: String? }
}
