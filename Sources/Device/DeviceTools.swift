import EventKit
import Foundation

// MARK: - 本机信息工具：今日概览、日历读取/创建、提醒事项创建、备忘录搜索
//
// 这些是"访问用户本机数据"的常驻工具（同日程工具，不受联网开关控制）。
// 权限首次调用时弹系统授权框；拒绝时返回带设置路径的指引文案，
// 模型会把指引转告用户。时间参数约定：
//   · "HH:MM" → 今天该时刻；完整 "yyyy-MM-dd HH:MM" → 指定那天
//   · 缺省 end = start + 1 小时（日历）；all_day 时 end 缺省 = start + 1 天
//   · calendar_read 的 day 是起点（today/tomorrow/yesterday），days 是连续天数
//     （默认 7 = 一周，最多 30；只看某天传 days: 1，多天按天分组输出）
//
// apple_pim_today 对齐桌面端 @local/apple-pim（2026-11-20 单工具版）：
//   · 提醒：未完成的「今日到期 + 已逾期 + days_ahead 窗口内」，逾期判定用今天零点
//   · 日程：与 [今天0点, 今天0点 + (1 + days_ahead) 天) 相交，全天/跨天都给全
//   · 输出 JSON 文本，字段与顺序按桌面端 output schema（index.js:440-456）

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

// MARK: 日期换算（纯函数，可单测）

enum DeviceToolCalendar {
    /// day 参数（today/tomorrow/yesterday）→ 当天本地零点；未知值返回 nil
    static func day(named: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let offset: Int
        switch named {
        case "today": offset = 0
        case "tomorrow": offset = 1
        case "yesterday": offset = -1
        default: return nil
        }
        var cal = Calendar.current
        cal.timeZone = timeZone
        guard let date = cal.date(byAdding: .day, value: offset, to: now) else { return nil }
        return cal.startOfDay(for: date)
    }

    /// 某天 00:00–24:00 的区间（calendar_read 单日）
    static func dayRange(of date: Date, timeZone: TimeZone = .current) -> (start: Date, end: Date) {
        range(of: date, days: 1, timeZone: timeZone)
    }

    /// calendar_read 一次最多看多少天（与 apple_pim_today 的 days_ahead 上限一致）
    static let maxDays = 30

    /// 不传 days 时默认看一周（今天起 7 天）
    static let defaultDays = 7

    /// calendar_read 的 days 参数：缺省 → 一周；非数字 / 小于 1 → 1 天；上限夹到 maxDays
    static func clampDays(_ raw: Double?) -> Int {
        guard let raw else { return defaultDays }
        guard raw.isFinite, raw >= 1 else { return 1 }
        return min(Int(raw.rounded(.down)), maxDays)
    }

    /// 从某天起连续 days 天的区间：[当天 0 点, 当天 0 点 + days 天)。不足 1 天按 1 天。
    static func range(of date: Date, days: Int, timeZone: TimeZone = .current) -> (start: Date, end: Date) {
        var cal = Calendar.current
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: date)
        let span = max(1, days)
        let end = cal.date(byAdding: .day, value: span, to: start)
            ?? start.addingTimeInterval(Double(span) * 86_400)
        return (start, end)
    }
}

// MARK: 今日概览语义：窗口 / 逾期 / 过滤 / 排序（纯函数，可单测）

/// 对应桌面端 reminders.applescript:28-49 与 calendar.applescript:33-42 的窗口规则。
enum ApplePIMSemantics {
    /// days_ahead 上限（桌面 index.js:518 夹到 30）
    static let maxDaysAhead = 30
    /// 事件输出安全上限（桌面 maxItems=40 只用于启动注入文案；工具本身返回全量，
    /// iOS 这里给 200 条保险丝，超限通过 errors 明确告知而不是静默截断）
    static let maxEvents = 200

    /// 桌面端：非数字 / 非正数一律按 0，正数取 floor 并夹到 30
    static func clampDaysAhead(_ raw: Double?) -> Int {
        guard let raw, raw.isFinite, raw > 0 else { return 0 }
        return min(Int(raw.rounded(.down)), maxDaysAhead)
    }

    /// 某个时刻所在本地日的零点
    static func dayStart(_ date: Date, timeZone: TimeZone) -> Date {
        var cal = Calendar.current
        cal.timeZone = timeZone
        return cal.startOfDay(for: date)
    }

    /// 查询窗口：[今天 0 点, 今天 0 点 + (1 + daysAhead) 天)
    static func window(now: Date, daysAhead: Int, timeZone: TimeZone) -> (start: Date, end: Date) {
        var cal = Calendar.current
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: now)
        let days = 1 + max(0, daysAhead)
        let end = cal.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
        return (start, end)
    }

    /// 逾期 = 截止时间早于「今天零点」（桌面 reminders.applescript:47 `d < dayStart`）。
    /// 今天更早时刻到期但还没过零点的，算今天而非逾期。
    static func isOverdue(_ due: Date?, now: Date, timeZone: TimeZone) -> Bool {
        guard let due else { return false }
        return due < dayStart(now, timeZone: timeZone)
    }

    /// 提醒窗口过滤：未完成（bridge 已筛）且有截止时间的保留到 due < 窗口结束；
    /// 无截止时间的保留（intentional 偏差，见 DeviceReminderItem 注释）。
    static func filterReminders(_ items: [DeviceReminderItem], now: Date,
                                daysAhead: Int, timeZone: TimeZone) -> [DeviceReminderItem] {
        let bounds = window(now: now, daysAhead: daysAhead, timeZone: timeZone)
        return items.filter { item in
            guard let due = item.due else { return true }
            return due < bounds.end
        }
    }

    /// 排序：有截止的按 due 升序（逾期在前 → 今天 → 未来），无截止的排最后；
    /// 同一时刻按标题、id 稳定排序。
    static func sortReminders(_ items: [DeviceReminderItem]) -> [DeviceReminderItem] {
        items.sorted { lhs, rhs in
            if let left = lhs.due, let right = rhs.due {
                if left != right { return left < right }
            } else if lhs.due == nil && rhs.due != nil {
                return false
            } else if lhs.due != nil && rhs.due == nil {
                return true
            }
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    /// 日程窗口过滤：与 [start, end) 相交即保留（全天/跨天事件都在其中）
    static func filterEvents(_ items: [DeviceEventItem], now: Date,
                             daysAhead: Int, timeZone: TimeZone) -> [DeviceEventItem] {
        let bounds = window(now: now, daysAhead: daysAhead, timeZone: timeZone)
        return items.filter { $0.start < bounds.end && $0.end > bounds.start }
    }

    /// 日程排序：开始时间升序，其次结束、日历、标题（保证输出稳定）
    static func sortEvents(_ items: [DeviceEventItem]) -> [DeviceEventItem] {
        items.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            if lhs.calendar != rhs.calendar {
                return lhs.calendar.localizedStandardCompare(rhs.calendar) == .orderedAscending
            }
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

// MARK: 展示格式化（纯函数，可单测）

enum DeviceToolFormatter {
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.timeZone = timeZone
        return hm.string(from: date)
    }

    static func monthDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f.string(from: date)
    }

    static func rangeLabel(start: Date, end: Date, timeZone: TimeZone = .current) -> String {
        "\(clock(start, timeZone: timeZone))–\(clock(end, timeZone: timeZone))"
    }

    /// 桌面 index.js:334-343：全天显示「全天」；跨天带日期；同天只显示时间
    static func timeRangeText(_ event: DeviceEventItem, timeZone: TimeZone = .current) -> String {
        guard !event.allDay else { return "全天" }
        var cal = Calendar.current
        cal.timeZone = timeZone
        if cal.isDate(event.start, inSameDayAs: event.end) {
            return rangeLabel(start: event.start, end: event.end, timeZone: timeZone)
        }
        return "\(monthDay(event.start, timeZone: timeZone)) \(clock(event.start, timeZone: timeZone))"
            + " – \(monthDay(event.end, timeZone: timeZone)) \(clock(event.end, timeZone: timeZone))"
    }

    /// 单条事件的一行文本：「时间 标题（地点）（日历「X」）」
    static func eventLine(_ event: DeviceEventItem, timeZone: TimeZone = .current) -> String {
        let title = event.title.isEmpty ? "(无标题)" : event.title
        var line = "\(timeRangeText(event, timeZone: timeZone)) \(title)"
        if !event.location.isEmpty { line += "（\(event.location)）" }
        if !event.calendar.isEmpty { line += "（日历「\(event.calendar)」）" }
        return line
    }

    /// calendar_read 的文本：每行「时间 标题（地点）（日历「X」）」
    static func eventsText(_ events: [DeviceEventItem], timeZone: TimeZone = .current) -> String {
        guard !events.isEmpty else { return "那天日历上是空的。" }
        return events.map { eventLine($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    /// 多天窗口里每天最多列多少条（超出时明确告知，不静默截断）
    static let maxMultiDayLines = 120

    /// 「11/25 周二」
    static func dayLabel(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d EEE"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// calendar_read 多天窗口的文本：先给查询范围，再按天分组，空的当天明确写「（没有日程）」，
    /// 让模型一眼看出哪几天占满、哪几天空着（只发有事件的日子会让空档变得含糊）。
    static func multiDayEventsText(_ events: [DeviceEventItem], from start: Date, to end: Date,
                                   timeZone: TimeZone = .current) -> String {
        var cal = Calendar.current
        cal.timeZone = timeZone
        let firstDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)

        // 按「开始日」归组；窗口之前就开始的跨天事件算进第一天
        var grouped: [Date: [DeviceEventItem]] = [:]
        for event in events.sorted(by: { $0.start < $1.start }) {
            let day = max(cal.startOfDay(for: event.start), firstDay)
            grouped[day, default: []].append(event)
        }

        var days: [Date] = []
        var cursor = firstDay
        while cursor < endDay {
            days.append(cursor)
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard let lastDay = days.last else { return eventsText(events, timeZone: timeZone) }

        var lines = ["查询范围：\(dayLabel(firstDay, timeZone: timeZone)) – \(dayLabel(lastDay, timeZone: timeZone))"
                     + "（\(days.count) 天，共 \(events.count) 个日程）"]
        guard !events.isEmpty else {
            lines.append("这几天日历上是空的。")
            return lines.joined(separator: "\n")
        }

        var printed = 0
        var hidden = 0
        for day in days {
            let items = grouped[day] ?? []
            let head = dayLabel(day, timeZone: timeZone)
            lines.append(items.isEmpty ? "\(head)（没有日程）" : head)
            for event in items {
                if printed >= maxMultiDayLines {
                    hidden += 1
                    continue
                }
                lines.append("· \(eventLine(event, timeZone: timeZone))")
                printed += 1
            }
        }
        if hidden > 0 {
            lines.append("……还有 \(hidden) 个日程没显示（单次最多 \(maxMultiDayLines) 条，可以把 days 调小分几次看）。")
        }
        return lines.joined(separator: "\n")
    }

    // 兼容期临时保留：Lead 接线前 RemindersReadTool 还在用，接线后连同工具一起移除。
    static func remindersText(_ reminders: [DeviceReminderItem]) -> String {
        guard !reminders.isEmpty else { return "没有未完成的提醒事项。" }
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return reminders.map { reminder -> String in
            var line = "· \(reminder.title)"
            if let due = reminder.due { line += "（到期：\(f.string(from: due))）" }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: apple_pim_today 输出 JSON（纯函数，可单测）

/// 手动拼 JSON：字段顺序与桌面端 output schema 一致（JSONEncoder 不保证顺序）。
enum ApplePIMJSON {
    /// 日期标题，桌面 index.js:526 的 zh-CN Intl 输出形如「2026年11月22日星期日」
    static func dateLabel(now: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        f.dateFormat = "yyyy年M月d日EEEE"
        return f.string(from: now)
    }

    /// 提醒事项 due：桌面 AppleScript 的 «class isot» 是「本地时间、不带时区」，
    /// 这里保持同样形状（yyyy-MM-dd'T'HH:mm:ss），模型自己对照 date/时区判断今天。
    static func isoLocal(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    /// 日程 start/end：桌面端用 toISOString()（UTC，带毫秒 Z 结尾），这里保持一致
    static func isoUTC(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// JSON 字符串字面量（含引号与转义）
    static func stringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""        // "
            case 0x5C: out += "\\\\"        // \
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case let code where code < 0x20:
                out += String(format: "\\u%04x", code)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// 组装 {"date","timeZone","reminders","events","errors"}。
    /// reminders / events 需是已按窗口过滤并排序好的列表；overdue 在这里用今天零点算。
    static func digest(now: Date, timeZone: TimeZone,
                       reminders: [DeviceReminderItem],
                       events: [DeviceEventItem],
                       errors: [String]) -> String {
        let dayStart = ApplePIMSemantics.dayStart(now, timeZone: timeZone)
        let reminderJSON = reminders.map { item -> String in
            let due = item.due.map { isoLocal($0, timeZone: timeZone) } ?? ""
            let overdue = item.due.map { $0 < dayStart } ?? false
            return object([
                ("id", stringLiteral(item.id)),
                ("title", stringLiteral(item.title)),
                ("list", stringLiteral(item.list)),
                ("due", stringLiteral(due)),
                ("overdue", overdue ? "true" : "false"),
            ])
        }
        let eventJSON = events.map { event -> String in
            object([
                ("id", stringLiteral(event.id)),
                ("calendar", stringLiteral(event.calendar)),
                ("title", stringLiteral(event.title)),
                ("start", stringLiteral(isoUTC(event.start))),
                ("end", stringLiteral(isoUTC(event.end))),
                ("allDay", event.allDay ? "true" : "false"),
                ("location", stringLiteral(event.location)),
            ])
        }
        return object([
            ("date", stringLiteral(dateLabel(now: now, timeZone: timeZone))),
            ("timeZone", stringLiteral(timeZone.identifier)),
            ("reminders", "[" + reminderJSON.joined(separator: ",") + "]"),
            ("events", "[" + eventJSON.joined(separator: ",") + "]"),
            ("errors", "[" + errors.map(stringLiteral).joined(separator: ",") + "]"),
        ])
    }

    private static func object(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\(stringLiteral($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }
}

// MARK: apple_pim_today 参数（容错解码，可单测）

struct ApplePIMTodayArgs {
    var daysAhead: Double?
    var includeReminders: Bool?
    var includeCalendar: Bool?

    /// 参数容错：字段缺失/类型不对/整段不是 JSON 都退回默认值（days_ahead=0、双源开）。
    /// 与桌面 index.js:518-522 一致：days_ahead 必须是数字，布尔开关只认 true/false。
    static func decode(_ argumentsJSON: String) -> ApplePIMTodayArgs {
        guard let data = argumentsJSON.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return ApplePIMTodayArgs()
        }
        return ApplePIMTodayArgs(daysAhead: raw.daysAhead,
                                 includeReminders: raw.includeReminders,
                                 includeCalendar: raw.includeCalendar)
    }

    private struct Raw: Decodable {
        var daysAhead: Double?
        var includeReminders: Bool?
        var includeCalendar: Bool?

        enum CodingKeys: String, CodingKey {
            case daysAhead = "days_ahead"
            case includeReminders = "include_reminders"
            case includeCalendar = "include_calendar"
        }

        /// 逐字段容错解码：某个字段类型不对只丢该字段，不影响其它字段
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            daysAhead = (try? container.decodeIfPresent(Double.self, forKey: .daysAhead)) ?? nil
            includeReminders = (try? container.decodeIfPresent(Bool.self, forKey: .includeReminders)) ?? nil
            includeCalendar = (try? container.decodeIfPresent(Bool.self, forKey: .includeCalendar)) ?? nil
        }
    }
}

// MARK: 今日概览（apple_pim_today，对应桌面端 @local/apple-pim 的查询工具）

struct ApplePIMTodayTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "apple_pim_today",
            description: "读取用户手机「提醒事项」与「日历」中今天的数据：未完成的今日到期与已逾期提醒、今天的日程（可扩展到未来几天）。用户问「我今天有什么待办」「今天/明天忙不忙」「这周有什么安排」时用。返回 JSON 文本；首次调用可能触发系统授权或较慢。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "days_ahead": .object([
                        "type": .string("number"),
                        "description": .string("额外包含的未来天数，默认 0（仅今天与逾期）。最大 30。"),
                    ]),
                    "include_reminders": .object([
                        "type": .string("boolean"),
                        "description": .string("是否包含提醒事项，默认 true。"),
                    ]),
                    "include_calendar": .object([
                        "type": .string("boolean"),
                        "description": .string("是否包含日历日程，默认 true。"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        let args = ApplePIMTodayArgs.decode(argumentsJSON)
        let daysAhead = ApplePIMSemantics.clampDaysAhead(args.daysAhead)
        let includeReminders = args.includeReminders ?? true
        let includeCalendar = args.includeCalendar ?? true
        let now = Date()
        let timeZone = TimeZone.current

        var reminders: [DeviceReminderItem] = []
        var events: [DeviceEventItem] = []
        var errors: [String] = []

        if includeReminders {
            if let denial = await bridge.requestRemindersAccess() {
                errors.append("reminders: \(denial)")
            } else {
                do {
                    let all = try await bridge.reminderItems()
                    reminders = ApplePIMSemantics.sortReminders(
                        ApplePIMSemantics.filterReminders(all, now: now,
                                                          daysAhead: daysAhead, timeZone: timeZone))
                } catch {
                    errors.append("reminders: \(error.localizedDescription)")
                }
            }
        }

        if includeCalendar {
            if let denial = await bridge.requestCalendarAccess() {
                errors.append("calendar: \(denial)")
            } else {
                do {
                    let bounds = ApplePIMSemantics.window(now: now, daysAhead: daysAhead, timeZone: timeZone)
                    let all = try bridge.eventItems(from: bounds.start, to: bounds.end)
                    var visible = ApplePIMSemantics.sortEvents(
                        ApplePIMSemantics.filterEvents(all, now: now,
                                                       daysAhead: daysAhead, timeZone: timeZone))
                    if visible.count > ApplePIMSemantics.maxEvents {
                        errors.append("calendar: 窗口内事件共 \(visible.count) 个，超过 \(ApplePIMSemantics.maxEvents) 条安全上限，只返回前 \(ApplePIMSemantics.maxEvents) 个")
                        visible = Array(visible.prefix(ApplePIMSemantics.maxEvents))
                    }
                    events = visible
                } catch {
                    errors.append("calendar: \(error.localizedDescription)")
                }
            }
        }

        // 全部来源都失败时也返回带 errors 的结构：权限指引文案本身就在 errors 里
        return ApplePIMJSON.digest(now: now, timeZone: timeZone,
                                   reminders: reminders, events: events, errors: errors)
    }
}

// MARK: 日历读取

struct CalendarReadTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "calendar_read",
            description: "查看用户手机日历上的日程安排（跨 App 的真实日历，不是你自己的生活日程）。默认从 day 起看一周（7 天）：不传 days 就是一周，多天按天分组、空的日子也会列出来；只要某一天传 days=1；要看更久最多 30 天。用户问「这周有什么安排」「未来几天忙不忙」「后天有什么」直接用默认一周；只问当天或明天的细节时传 days=1。全天事件显示「全天」，跨天事件带日期。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "day": .object([
                        "type": .string("string"),
                        "enum": .array([.string("today"), .string("tomorrow"), .string("yesterday")]),
                        "description": .string("从哪一天开始看，默认 today。"),
                    ]),
                    "days": .object([
                        "type": .string("number"),
                        "description": .string("从 day 那天起连续看几天，1–30，默认 7（一周）。只要某一天传 1；「这周 / 未来一周」保持默认。"),
                    ]),
                ]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        let args = CalendarReadArgs.decode(argumentsJSON)
        let dayName = args.day ?? "today"
        guard let date = DeviceToolCalendar.day(named: dayName) else {
            return "{\"error\": \"day 只能是 today / tomorrow / yesterday\"}"
        }
        let days = DeviceToolCalendar.clampDays(args.days)
        if let denial = await bridge.requestCalendarAccess() { return denial }
        do {
            let bounds = DeviceToolCalendar.range(of: date, days: days)
            let events = try bridge.eventItems(from: bounds.start, to: bounds.end)
            return days == 1
                ? DeviceToolFormatter.eventsText(events)
                : DeviceToolFormatter.multiDayEventsText(events, from: bounds.start, to: bounds.end)
        } catch {
            return "日历读取失败：\(error.localizedDescription)"
        }
    }
}

// MARK: calendar_read 参数（容错解码，可单测）

struct CalendarReadArgs {
    var day: String?
    var days: Double?

    init(day: String?, days: Double?) {
        self.day = day
        self.days = days
    }

    /// 缺字段 / 类型不对 / 整段不是 JSON 都退回缺省（今天、1 天），与 apple_pim_today 同风格
    static func decode(_ json: String) -> CalendarReadArgs {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return CalendarReadArgs(day: nil, days: nil)
        }
        return CalendarReadArgs(day: raw.day, days: raw.days)
    }

    private struct Raw: Decodable {
        var day: String?
        var days: Double?

        enum CodingKeys: String, CodingKey { case day, days }

        /// 逐字段容错：某个字段类型不对只丢该字段
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = (try? container.decodeIfPresent(String.self, forKey: .day)) ?? nil
            days = (try? container.decodeIfPresent(Double.self, forKey: .days)) ?? nil
        }
    }
}

// MARK: 日历创建

struct CalendarCreateTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "calendar_create",
            description: "在用户手机日历上新建一个日程事件。用户说「帮我记一下周三下午三点开会」这类请求时用。title 必填；start 必填（HH:MM 表示今天，或 yyyy-MM-dd HH:MM）；end 缺省 = start + 1 小时（all_day 时 = 次日 0 点）。结束时间必须晚于开始时间。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("事件标题")]),
                    "start": .object(["type": .string("string"), "description": .string("开始时间：HH:MM（今天）或 yyyy-MM-dd HH:MM")]),
                    "end": .object(["type": .string("string"), "description": .string("结束时间，格式同 start；缺省 = 开始 + 1 小时（all_day 时 = 次日 0 点）")]),
                    "all_day": .object(["type": .string("boolean"), "description": .string("是否全天事件（默认 false）")]),
                    "location": .object(["type": .string("string"), "description": .string("地点（可选）")]),
                ]),
                "required": .array([.string("title"), .string("start")]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        guard let args = try? JSONDecoder().decode(CreateArgs.self, from: Data(argumentsJSON.utf8)) else {
            return "{\"error\": \"参数需要 JSON：title 必填，start 必填\"}"
        }
        let isAllDay = args.allDay ?? false
        // 先校验参数再申请权限：参数不对时不弹授权框、不写坏数据
        guard let start = DeviceToolDateParser.parse(args.start) else {
            return "开始时间没看懂：\(args.start)。请用 HH:MM 或 yyyy-MM-dd HH:MM 格式。未创建任何日程。"
        }
        let end: Date
        if let endText = args.end {
            guard let parsed = DeviceToolDateParser.parse(endText, baseDay: start) else {
                return "结束时间没看懂：\(endText)。请用 HH:MM 或 yyyy-MM-dd HH:MM 格式。未创建任何日程。"
            }
            end = parsed
        } else {
            end = start.addingTimeInterval(isAllDay ? 86_400 : 3_600)
        }
        guard end > start else {
            return "结束时间必须晚于开始时间（\(DeviceToolFormatter.rangeLabel(start: start, end: end))）。未创建任何日程。"
        }
        if let denial = await bridge.requestCalendarAccess() { return denial }
        do {
            _ = try bridge.createEvent(title: args.title, startDate: start, endDate: end, allDay: isAllDay,
                                       location: args.location?.isEmpty == true ? nil : args.location)
            let when = isAllDay
                ? "\(DeviceToolFormatter.monthDay(start)) 全天"
                : DeviceToolFormatter.rangeLabel(start: start, end: end)
            return "已写入日历：\(when) \(args.title)。回复里用自己的口吻确认即可。"
        } catch {
            return "写入日历失败：\(error.localizedDescription)"
        }
    }

    private struct CreateArgs: Decodable {
        let title: String
        let start: String
        let end: String?
        let allDay: Bool?
        let location: String?

        enum CodingKeys: String, CodingKey {
            case title, start, end, location
            case allDay = "all_day"
        }
    }
}

// MARK: 提醒事项创建

struct RemindersCreateTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "reminders_create",
            description: "在用户手机「提醒事项」App 里新建一条提醒。用户说「提醒我明天上午买牛奶」这类请求时用。due 可选（HH:MM 表示今天，或 yyyy-MM-dd HH:MM），格式不对会报错、不会创建。",
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
        // due 给了就必须能解析；解析失败直接报错、不创建（以前是静默当成无截止）
        var due: Date?
        if let dueText = args.due, !dueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = DeviceToolDateParser.parse(dueText) else {
                return "到期时间没看懂：\(dueText)。请用 HH:MM（今天）或 yyyy-MM-dd HH:MM 格式；不需要截止时间就不要传 due。未创建任何提醒。"
            }
            due = parsed
        }
        if let denial = await bridge.requestRemindersAccess() { return denial }
        do {
            _ = try bridge.createReminder(title: args.title, due: due)
            return "已加入提醒事项：\(args.title)。回复里用自己的口吻确认即可。"
        } catch {
            return "写入提醒事项失败：\(error.localizedDescription)"
        }
    }

    private struct CreateArgs: Decodable { let title: String; let due: String? }
}

// 兼容期临时保留：Lead 把 FenShenApp 里的引用换成 ApplePIMTodayTool 后删除本结构与
// DeviceToolFormatter.remindersText（apple_pim_today 已覆盖其读语义）。
struct RemindersReadTool: AgentTool {
    let bridge = EventKitBridge.shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "reminders_read",
            description: "查看用户手机「提醒事项」App 里未完成的提醒。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        if let denial = await bridge.requestRemindersAccess() { return denial }
        do {
            return DeviceToolFormatter.remindersText(try await bridge.reminderItems())
        } catch {
            return "提醒事项读取失败：\(error.localizedDescription)"
        }
    }
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
