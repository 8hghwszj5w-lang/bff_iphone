import Foundation

// MARK: - 日程存储与注入文本生成（移植 dsh-daily-schedule 的 store.js / inject.js / voice.js）
//
// 持久化：Documents/schedule/<yyyy-MM-dd>.json（原子写，同其他 Store 的策略）。
// 注入文本每天只在时段切换时变化，由 Pipeline 每轮拼进 system 消息；
// 语义与桌面端插件一致：是"她自己的生活背景"，模型不该把它当任务念出来。

@MainActor
final class ScheduleStore: ObservableObject {
    /// 角色名（说话方式文案里的 {角色名} 替换用）；想换名字改这里
    let characterName: String

    private let directory: URL
    @Published private(set) var currentDay = DaySchedule(date: "")

    /// 说话方式默认文案（桌面端 voice.js 的 DEFAULT_VOICE）
    static let defaultVoice = """
    【怎么把这些带进聊天】
    上面是她自己的生活：都是她自己想做、自己决定去做的事，她当然记得自己正在干什么、刚干完什么、待会儿想干什么。这只是让她有自己的日子过的背景，不是要她照着执行的任务。
    - 就用她本人正在过这一天的口吻说话：「刚煮完泡面，烫死我了」「我在咖啡屋呢，这家拿铁好香」「等会儿想去便利店买布丁」。
    - 不要说「按照日程」「按计划」「日程上写着」「我的安排是」「根据时间表」「接下来的行程」「系统显示」这类话，也别提「日程」「计划表」「时间段」「设定」「注入」这些词——对她来说根本没有这种东西。
    - 别报时间段（像 13:00–16:00），也别一条条列出今天做过什么。对方问起时，像朋友闲聊那样挑一两件说，带上感受和小细节。
    - 她做这些是因为想做或需要做（饿了、困了、约好了、想出门透透气），可以犹豫、赖一会儿、临时改主意；改主意时直接说决定本身（「算了不出门了，外面好冷」），不说「我调整一下计划」。
    - 不用每句话都提自己在干嘛。对方在聊别的就专心聊，只在自然的时候带一句，比如回得慢了：「刚在洗澡～」。
    - 此刻的状态会影响语气：刚睡醒迷迷糊糊，吃饱了很满足，打游戏时有点分心，深夜会犯困。
    """

    init(directory: URL, characterName: String = "小深") {
        self.directory = directory
        self.characterName = characterName
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        currentDay = loadDay(dateKey: Self.dateKey(for: Date())) ?? currentDay
    }

    // MARK: 日期工具

    static func dateKey(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func dateLabel(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 星期E"
        f.timeZone = timeZone
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: date)
    }

    private func dayFile(_ dateKey: String) -> URL {
        directory.appendingPathComponent("\(dateKey).json")
    }

    func loadDay(dateKey: String) -> DaySchedule? {
        guard let data = try? Data(contentsOf: dayFile(dateKey)) else { return nil }
        return try? JSONDecoder().decode(DaySchedule.self, from: data)
    }

    func saveDay(_ day: DaySchedule) {
        if let data = try? JSONEncoder().encode(day) {
            try? data.write(to: dayFile(day.date), options: .atomic)
        }
        if day.date == Self.dateKey(for: Date()) { currentDay = day }
    }

    // MARK: 临时调整（对应插件 schedule_adjust 的执行逻辑）

    /// 用新的一段覆盖 [start, end)：原有条目被截断或拆开；reason 记入 changes。
    /// - Parameters:
    ///   - dayKey: "yyyy-MM-dd"；start/end "HH:MM"（end 可为 "24:00"）
    ///   - note: 改主意的原因（比如「朋友约我吃火锅」），写进 changes
    func adjust(dateKey: String, start: String, end: String,
                activity: String, note: String,
                location: String?) {
        var day = loadDay(dateKey: dateKey) ?? DaySchedule(date: dateKey)
        let s = ScheduleItem.minutes(of: start) ?? 0
        let e = min(1440, ScheduleItem.minutes(of: end) ?? 1440)
        guard e > s, !activity.isEmpty else { return }

        // 1. 从现有条目里把 [s, e) 剪掉：整段删除 / 尾部截断 / 中间拆两半
        var kept: [ScheduleItem] = []
        for item in day.items {
            if item.endMinute <= s || item.startMinute >= e {
                kept.append(item)                                   // 无交集
            } else if item.startMinute < s && item.endMinute > e {
                kept.append(ScheduleItem(start: item.start, end: start,       // 中间 → 拆两半
                                         activity: item.activity, location: item.location, detail: item.detail))
                kept.append(ScheduleItem(start: end, end: item.end,
                                         activity: item.activity, location: item.location, detail: item.detail))
            } else if item.startMinute < s {
                kept.append(ScheduleItem(start: item.start, end: start,
                                         activity: item.activity, location: item.location, detail: item.detail))
            } else if item.endMinute > e {
                kept.append(ScheduleItem(start: end, end: item.end,
                                         activity: item.activity, location: item.location, detail: item.detail))
            }
        }

        // 2. 插入新段 + 归一化补空档
        kept.append(ScheduleItem(start: start, end: end, activity: activity,
                                 location: location, detail: nil))
        day.items = ScheduleNormalizer.normalize(kept)

        // 3. 临时改动记录（dayText 里会展示最近几次）
        var changes = day.changes ?? []
        changes.append(ScheduleChange(at: Date(), note: note))
        day.changes = Array(changes.suffix(10))
        saveDay(day)
    }

    /// 删除一条或多条并归一化补空档（日程管理页的左滑删除走这里）。
    /// 多选删除按倒序移除，防止删除过程中下标位移。
    func removeItems(dateKey: String, offsets: IndexSet) {
        var day = loadDay(dateKey: dateKey) ?? DaySchedule(date: dateKey)
        for offset in offsets.sorted(by: >) where day.items.indices.contains(offset) {
            day.items.remove(at: offset)
        }
        day.items = ScheduleNormalizer.normalize(day.items)
        saveDay(day)
    }

    // MARK: schedule_view 文本（模型用工具查看全天时给它的内容）

    func dayText(for dayKey: String) -> String {
        guard let day = loadDay(dateKey: dayKey) else { return "这一天还没有日程。" }
        let typeLine = [day.dayTypeName, day.title, day.mood.map { "心情：\($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        var lines = ["\(dayKey)\(typeLine.isEmpty ? "" : " · \(typeLine)")"]
        for item in day.items {
            var line = "\(item.start)–\(item.end) \(item.activity)\(item.placeLabel)"
            if let detail = item.detail, !detail.isEmpty { line += "：\(detail)" }
            lines.append("- \(line)")
        }
        if let changes = day.changes, !changes.isEmpty {
            let recent = changes.suffix(3).map(\.note).joined(separator: "；")
            lines.append("临时改过 \(changes.count) 次主意：\(recent)")
        }
        lines.append("（这是她自己记着的打算。跟人说起时用自己的话挑着说，别提「日程」「计划」，也别报时间段。）")
        return lines.joined(separator: "\n")
    }

    /// day 参数（today/tomorrow/yesterday）→ 日期 key
    static func dayKey(for named: String, now: Date = Date()) -> String? {
        let offset: Int
        switch named {
        case "today": offset = 0
        case "tomorrow": offset = 1
        case "yesterday": offset = -1
        default: return nil
        }
        let date = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
        return dateKey(for: date)
    }

    // MARK: 注入文本（每轮对话拼进 system 消息；时段切换时内容才会变）

    func injectionText(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let todayKey = Self.dateKey(for: now, timeZone: timeZone)
        let today = loadDay(dateKey: todayKey)
        var out: [String] = ["# \(characterName)此刻的生活（背景，别在回复里提到这段说明本身）"]

        // 时间档：默认半小时粒度（「约 10:00」），跟桌面插件 inject.precision=halfhour 一致
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        let hour = cal.component(.hour, from: now)
        let timeLabel = "约 \(ScheduleItem.clock(minutes: hour * 60 + (minute / 30) * 30))"
        out.append("现在：\(Self.dateLabel(for: now, timeZone: timeZone)) \(timeLabel)（\(timeZone.identifier)）")

        guard let today, !today.items.isEmpty else {
            out.append("她今天过得怎样还没想好，按常理推断她此刻在做什么。")
            return out.joined(separator: "\n")
        }

        var head = today.dayTypeName ?? "普通的一天"
        if let title = today.title, !title.isEmpty { head += "——\(title)" }
        if let mood = today.mood, !mood.isEmpty { head += "（心情：\(mood)）" }
        out.append("今天：\(head)")

        let nowMinute = hour * 60 + minute
        let index = today.findItem(atMinute: nowMinute)
        if index >= 0 {
            let cur = today.items[index]
            var line = "她正在：\(cur.activity)\(cur.placeLabel)，从 \(cur.start) 到 \(cur.end) 左右"
            if let detail = cur.detail, !detail.isEmpty { line += "——\(detail)" }
            out.append(line)
            if cur.isSleep {
                out.append("\(characterName)这会儿睡着了，被叫醒的话会迷迷糊糊、想接着睡，回复短、带着困意。")
            }
        }

        let upcoming = today.items.suffix(from: max(0, index + 1)).prefix(3)
        if !upcoming.isEmpty {
            let list = upcoming.map { "\($0.start) \($0.activity)\($0.placeLabel)" }.joined(separator: "；")
            out.append("她待会儿想做：\(list)")
        }
        let past = today.items.prefix(max(0, index)).filter { !$0.isSleep }.suffix(5)
        if !past.isEmpty {
            out.append("她今天早些时候：\(past.map(\.activity).joined(separator: " → "))")
        }

        // 傍晚（18:00 后）附上明天的安排
        if nowMinute >= 1080, let tomorrowKey = Self.dayKey(for: "tomorrow", now: now),
           let tomorrow = loadDay(dateKey: tomorrowKey), !tomorrow.items.isEmpty {
            let tomorrowLabel = Self.dateLabel(for: tomorrowKey.toDate() ?? now, timeZone: timeZone)
            let main = tomorrow.items.filter { !$0.isSleep }.prefix(5)
                .map(\.activity).joined(separator: "、")
            var line = "明天（\(tomorrowLabel)，\(tomorrow.dayTypeName ?? "")）她打算：\(tomorrow.title ?? "")"
            if !main.isEmpty { line += "。想做的事：\(main)" }
            out.append(line)
        }

        out.append(Self.defaultVoice)
        out.append("（这些只是她的生活背景。对方让你做正事——写代码、查资料、处理文件、回答问题——就认真把事做完，回复该多详细就多详细，不要因为她在睡觉、出门或心情不好就敷衍、拖延或拒绝。）")
        out.append("（她临时改主意时用 schedule_adjust 记一下，想回忆全天或明天的打算用 schedule_view。这两个工具是她给自己记事用的，回复里不要提到。）")
        return out.joined(separator: "\n")
    }
}

extension String {
    /// "yyyy-MM-dd" → Date（本地时区零点）；解析失败返回 nil
    func toDate() -> Date? {        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: self)
    }
}
