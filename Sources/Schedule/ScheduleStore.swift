import Foundation

// MARK: - 日程存储与注入文本生成（移植 dsh-daily-schedule 的 store.js / inject.js / voice.js / dress.js）
//
// 持久化：Documents/schedule/<yyyy-MM-dd>.json（原子写，同其他 Store 的策略）。
// 注入文本每天只在时段切换时变化，由 Pipeline 每轮拼进 system 消息；
// 语义与桌面端插件一致：是"她自己的生活背景"，模型不该把它当任务念出来。
// 穿搭 / 场景 / 物品 / 人物来自生图工作室的素材库快照（ScheduleWardrobe），
// 通过 wardrobeProvider 闭包注入，两个 Store 之间不直接互相持有。

@MainActor
final class ScheduleStore: ObservableObject {
    /// 角色名（说话方式文案里的 {角色名} 替换用）；想换名字改这里
    let characterName: String

    private let directory: URL
    @Published private(set) var currentDay = DaySchedule(date: "")

    /// 生图工作室素材库快照（对应桌面端 wardrobe.js 的 loadWardrobe）；
    /// 由 AppState 接线（studio.scheduleWardrobe()），nil = 没装生图工作室，按无素材库降级。
    var wardrobeProvider: (() -> ScheduleWardrobe?)?

    /// 注入到对话的总开关（对应桌面端配置 cfg.inject.enabled；桌面端按会话 /life 开关，
    /// iOS 单会话不移植，这里给一个全局开关，设置页可以关掉干正事）。
    static let injectEnabledDefaultsKey = "schedule.inject.enabled"
    @Published var injectEnabled: Bool {
        didSet { UserDefaults.standard.set(injectEnabled, forKey: Self.injectEnabledDefaultsKey) }
    }

    /// 说话方式默认文案（桌面端 voice.js 的 DEFAULT_VOICE，占位符由 voiceText 替换）
    static let defaultVoice = """
    【怎么把这些带进聊天】
    上面是{角色名}自己的生活：都是她自己想做、自己决定去做的事，她当然记得自己正在干什么、刚干完什么、待会儿想干什么。这只是让她有自己的日子过的背景，不是要她照着执行的任务。
    - 就用她本人正在过这一天的口吻说话：「刚煮完泡面，烫死我了」「我在咖啡屋呢，这家拿铁好香」「等会儿想去便利店买布丁」。
    - 不要说「按照日程」「按计划」「日程上写着」「我的安排是」「根据时间表」「接下来的行程」「系统显示」这类话，也别提「日程」「计划表」「时间段」「设定」「注入」这些词——对她来说根本没有这种东西。
    - 别报时间段（像 13:00–16:00），也别一条条列出今天做过什么。{称呼}问起时，像朋友闲聊那样挑一两件说，带上感受和小细节。
    - 她做这些是因为想做或需要做（饿了、困了、约好了、想出门透透气），可以犹豫、赖一会儿、临时改主意；改主意时直接说决定本身（「算了不出门了，外面好冷」），不说「我调整一下计划」。
    - 不用每句话都提自己在干嘛。{称呼}在聊别的就专心聊，只在自然的时候带一句，比如回得慢了：「刚在洗澡～」。
    - 此刻的状态会影响语气：刚睡醒迷迷糊糊，吃饱了很满足，打游戏时有点分心，深夜会犯困。
    """

    init(directory: URL, characterName: String = "小深") {
        self.directory = directory
        self.characterName = characterName
        let stored = UserDefaults.standard.object(forKey: Self.injectEnabledDefaultsKey) as? Bool
        self.injectEnabled = stored ?? true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        currentDay = loadDay(dateKey: Self.dateKey(for: Date())) ?? currentDay
    }

    // MARK: 日期工具

    // 主线程隔离，每种格式只保留一个实例；切换时区时再更新配置。
    private static let keyFormatter = formatter("yyyy-MM-dd", locale: "en_US_POSIX")
    /// 桌面端 time.js 的 dateLabel：'11月22日 星期日'（注意是 EEEE，不是「星期E」）
    private static let labelFormatter = formatter("M月d日 EEEE", locale: "zh_CN")

    private static func formatter(_ format: String, locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateFormat = format
        return formatter
    }

    static func dateKey(for date: Date, timeZone: TimeZone = .current) -> String {
        if keyFormatter.timeZone != timeZone { keyFormatter.timeZone = timeZone }
        return keyFormatter.string(from: date)
    }

    static func dateLabel(for date: Date, timeZone: TimeZone = .current) -> String {
        if labelFormatter.timeZone != timeZone { labelFormatter.timeZone = timeZone }
        return labelFormatter.string(from: date)
    }

    /// 日期 key → 桌面端风格的日期标签（schedule_view / 生成提示词用）
    static func dateLabel(forDayKey dayKey: String, timeZone: TimeZone = .current) -> String {
        guard let date = dayKey.toDate(timeZone: timeZone) else { return dayKey }
        return dateLabel(for: date, timeZone: timeZone)
    }

    /// 时刻档（桌面端 inject.js timeLabel，halfhour 精度：「约 10:00」）
    static func timeLabel(minute: Int) -> String {
        "约 \(ScheduleItem.clock(minutes: (minute / 30) * 30))"
    }

    /// 实际注入的说话方式（桌面端 voiceText / fillVoice：替换 {角色名}、{称呼}）
    static func voiceText(characterName: String, partnerName: String = "") -> String {
        let partner = partnerName.trimmingCharacters(in: .whitespaces).isEmpty ? "对方" : partnerName
        return defaultVoice
            .replacingOccurrences(of: "{角色名}", with: characterName)
            .replacingOccurrences(of: "{称呼}", with: partner)
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

    /// 当前可用的生图素材库快照（nil = 没接线 / 没装生图工作室）
    private var wardrobe: ScheduleWardrobe? { wardrobeProvider?() }

    // MARK: 临时调整（对应插件 index.js 的 schedule_adjust 执行逻辑）

    /// 临时调整的结果（区分「没有这一天」与「参数不合法」，工具侧给不同回复）
    enum AdjustResult: Equatable {
        case ok(DaySchedule)
        case noSchedule                       // 这一天还没有日程，不能凭空造一天
        case invalid(String)                  // 时间 / 活动参数不合法
    }

    /// 用新的一段覆盖 [start, end)：原有条目被截断或拆开；note 记入 changes。
    /// 与桌面端一致：这一天还没有日程时直接拒绝（不凭空造一天，否则 autoFill 会误判明天已生成）；
    /// 没写 outfit / outfitNote 时沿用该时间点原本的穿着；最后用素材库校验名字（fill = false）。
    /// - Parameters:
    ///   - dayKey: "yyyy-MM-dd"；start/end "HH:MM"（end 可为 "24:00"）
    ///   - note: 改主意的原因（比如「朋友约我吃火锅」），写进 changes
    @discardableResult
    func adjust(dateKey: String, start: String, end: String,
                activity: String, note: String,
                location: String? = nil, detail: String? = nil,
                outfit: String? = nil, outfitNote: String? = nil,
                scene: String? = nil, situation: String? = nil) -> AdjustResult {
        guard let s = ScheduleItem.minutes(of: start), let e = ScheduleItem.minutes(of: end) else {
            return .invalid("时间不对：start 和 end 用 HH:MM")
        }
        guard e > s else { return .invalid("时间不对：end 要晚于 start") }
        let trimmedActivity = ScheduleItem.oneLine(activity, 40)
        guard !trimmedActivity.isEmpty else { return .invalid("要写清楚做什么（activity）") }
        // 桌面端 index.js:88：没有这一天的日程就直接拒绝
        guard var day = loadDay(dateKey: dateKey) else { return .noSchedule }

        var change = ScheduleItem(start: start, end: end, activity: trimmedActivity,
                                  location: location.flatMap { ScheduleItem.optionalText($0, 30) },
                                  detail: detail.flatMap { ScheduleItem.optionalText($0, 240) },
                                  outfit: outfit.flatMap { ScheduleItem.optionalText($0, 40) },
                                  outfitNote: outfitNote.flatMap { ScheduleItem.optionalText($0, 60) },
                                  scene: scene.flatMap { ScheduleItem.optionalText($0, 40) },
                                  situation: situation.flatMap { ScheduleItem.optionalText($0, 20) })
        // 桌面端 index.js:89-96：没说换衣服，就沿用那个时间点原本的穿着
        let at = day.findItem(atMinute: s)
        if at >= 0 {
            let was = day.items[at]
            if (change.outfit ?? "").isEmpty, (change.outfitNote ?? "").isEmpty {
                change.outfit = was.outfit
                change.outfitNote = was.outfitNote
            }
        }

        // 1. 从现有条目里把 [s, e) 剪掉：整段删除 / 尾部截断 / 中间拆两半
        var kept: [ScheduleItem] = []
        for item in day.items {
            if item.endMinute <= s || item.startMinute >= e {
                kept.append(item)                                   // 无交集
                continue
            }
            if item.startMinute < s {
                var before = item
                before.end = start
                kept.append(before)
            }
            if item.endMinute > e {
                var after = item
                after.start = end
                kept.append(after)
            }
        }

        // 2. 插入新段 + 归一化补空档；素材库可用时校验名字（库里没有的 outfit 转成备注）
        kept.append(change)
        var items = ScheduleNormalizer.normalize(kept)
        items = ScheduleWardrobeLink.linkItems(items, wardrobe: wardrobe, fill: false)
        day.items = items

        // 3. 临时改动记录（dayText 里会展示最近几次；桌面端上限 30 条）
        var changes = day.changes ?? []
        changes.append(ScheduleChange(at: Date(), note: ScheduleItem.oneLine(note, 80)))
        day.changes = Array(changes.suffix(30))
        saveDay(day)
        return .ok(day)
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

    // MARK: schedule_view 文本（模型用工具查看全天时给它的内容；对应 inject.js dayText）

    func dayText(for dayKey: String) -> String {
        guard let day = loadDay(dateKey: dayKey) else { return "这一天还没有日程。" }
        var head = "\(Self.dateLabel(forDayKey: day.date.isEmpty ? dayKey : day.date)) · \(day.dayTypeName ?? "")"
        if let title = day.title, !title.isEmpty { head += " · \(title)" }
        if let mood = day.mood, !mood.isEmpty { head += "（心情：\(mood)）" }
        var lines = [head]
        for item in day.items {
            var tags: [String] = []
            if let situation = item.situation, !situation.isEmpty { tags.append("情境：\(situation)") }
            if !item.outfitLabel.isEmpty { tags.append("穿着：\(item.outfitLabel)") }
            if let props = item.props, !props.isEmpty { tags.append("物品：\(props.joined(separator: "、"))") }
            if let with = item.with, !with.isEmpty { tags.append("和：\(with.joined(separator: "、"))") }
            var line = "\(item.start)–\(item.end) \(item.activity)\(item.placeLabel)"
            if let detail = item.detail, !detail.isEmpty { line += "：\(detail)" }
            if !tags.isEmpty { line += " [\(tags.joined(separator: "；"))]" }
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
    //
    // 对应桌面端 inject.js injectionText：日期时间 → 今天是什么日子 → 此刻在做什么
    // （含穿着 / 手边物品 / 和谁在一起）→ 接下来几段 → 早些时候 → 换装时间线 →
    // 傍晚以后附明天的安排 → 说话方式 → 正事优先 → 工具提示 → 生图参数提示。

    func injectionText(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard injectEnabled else { return "" }
        var cal = Calendar.current
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let nowMinute = hour * 60 + minute
        let name = characterName
        let voice = Self.voiceText(characterName: name)

        var out: [String] = ["# \(name)此刻的生活（背景，别在回复里提到这段说明本身）"]
        out.append("现在：\(Self.dateLabel(for: now, timeZone: timeZone)) \(Self.timeLabel(minute: nowMinute))（\(timeZone.identifier)）")

        let todayKey = Self.dateKey(for: now, timeZone: timeZone)
        guard let today = loadDay(dateKey: todayKey), !today.items.isEmpty else {
            // 桌面端 inject.js:49-53：没有日程也照样带上说话方式（不然模型会突然变回念时间表的口气）
            out.append("她今天过得怎样还没想好，按常理推断她此刻在做什么。")
            if !voice.isEmpty { out.append(voice) }
            return out.joined(separator: "\n")
        }

        var dayHead = "今天：\(today.dayTypeName ?? "普通的一天")"
        if let title = today.title, !title.isEmpty { dayHead += "——\(title)" }
        if let mood = today.mood, !mood.isEmpty { dayHead += "（心情：\(mood)）" }
        out.append(dayHead)

        let index = today.findItem(atMinute: nowMinute)
        let current = index >= 0 ? today.items[index] : nil
        if let cur = current {
            var line = "她正在：\(cur.activity)\(cur.placeLabel)，从 \(cur.start) 到 \(cur.end) 左右"
            if let detail = cur.detail, !detail.isEmpty { line += "——\(detail)" }
            out.append(line)
            // 桌面端 inject.js:59-61：身上穿着 / 手边有 / 和谁在一起
            var extra: [String] = []
            let worn = cur.outfitLabel
            if !worn.isEmpty { extra.append("身上穿着\(worn)") }
            if let props = cur.props, !props.isEmpty { extra.append("手边有\(props.joined(separator: "、"))") }
            if let with = cur.with, !with.isEmpty { extra.append("和\(with.joined(separator: "、"))在一起") }
            if !extra.isEmpty { out.append("她\(extra.joined(separator: "，"))。") }
            if cur.isSleep {
                out.append("\(name)这会儿睡着了，被叫醒的话会迷迷糊糊、想接着睡，回复短、带着困意。")
            }
        }

        // 她待会儿想做：桌面端 inject.js:63-65（此刻之后 3 段；此刻查不到时从头算）
        let upcomingStart = index >= 0 ? index + 1 : 0
        let upcoming = Array(today.items.dropFirst(upcomingStart).prefix(3))
        if !upcoming.isEmpty {
            let list = upcoming.map { "\($0.start) \($0.activity)\($0.placeLabel)" }.joined(separator: "；")
            out.append("她待会儿想做：\(list)")
        }
        // 她今天早些时候：排除睡觉，最多 5 段（桌面端 inject.js:66-67）
        let past = today.items.prefix(max(0, index)).filter { !$0.isSleep }.suffix(5)
        if !past.isEmpty {
            out.append("她今天早些时候：\(past.map(\.activity).joined(separator: " → "))")
        }
        // 换装时间线（桌面端 inject.js:68-69 + dress.js outfitRuns）：只在换过衣服时出现
        let runs = ScheduleOutfit.runs(Array(today.items.prefix(max(0, index + 1))))
        if runs.count > 1 {
            out.append("她今天换过的衣服：\(ScheduleOutfit.text(runs))")
        }

        // 傍晚（默认 18:00）以后附上明天的安排（桌面端 inject.js:71-77）
        if nowMinute >= Self.tomorrowAfterMinute,
           let tomorrowDate = cal.date(byAdding: .day, value: 1, to: now),
           let tomorrow = loadDay(dateKey: Self.dateKey(for: tomorrowDate, timeZone: timeZone)) {
            let label = Self.dateLabel(for: tomorrowDate, timeZone: timeZone)
            let main = tomorrow.items.filter { !$0.isSleep }.prefix(5)
                .map(\.activity).joined(separator: "、")
            let firstOutfit = tomorrow.items.first { !$0.isSleep && !($0.outfit ?? "").isEmpty }?.outfit
            var line = "明天（\(label)，\(tomorrow.dayTypeName ?? "")）她打算：\(tomorrow.title ?? "")"
            if !main.isEmpty { line += "。想做的事：\(main)" }
            if let firstOutfit { line += "。想穿「\(firstOutfit)」" }
            out.append(line)
        }

        if !voice.isEmpty { out.append(voice) }
        // 正事优先（对应桌面端 voice.js priorityLine）
        out.append("（这些只是\(name)的生活背景。对方让你做正事——写代码、查资料、处理文件、回答问题——就认真把事做完，回复该多详细就多详细，不要因为她在睡觉、出门或心情不好就敷衍、拖延或拒绝。）")
        // 工具用法（对应桌面端 voice.js TOOL_LINE）
        out.append("（她临时改主意时用 schedule_adjust 记一下，想回忆全天或明天的打算用 schedule_view。这两个工具是她给自己记事用的，回复里不要提到。）")

        // 生图参数提示（对应桌面端 inject.js:82-84 / imageLine：装了生图工作室才有）
        if let wardrobe, let current {
            out.append(imageLine(wardrobe: wardrobe, item: current))
        }
        return out.joined(separator: "\n")
    }

    /// 桌面端默认 cfg.inject.tomorrowAfter = "18:00"
    private static let tomorrowAfterMinute = 18 * 60

    /// 生图时该填的参数：画的是她此刻的样子，就照日程填（桌面端 inject.js imageLine）。
    private func imageLine(wardrobe: ScheduleWardrobe, item: ScheduleItem) -> String {
        let on = ScheduleWardrobeLink.linkOn(wardrobe)
        var parts: [String] = []
        if !wardrobe.herName.isEmpty { parts.append("characters 填「\(wardrobe.herName)」") }
        let outfit = item.outfit ?? ""
        let note = item.outfitNote ?? ""
        if on.outfits {
            if !outfit.isEmpty {
                if note.isEmpty { parts.append("outfits 填「\(outfit)」") }
                else { parts.append("outfits 填「\(outfit)」，prompt 里写上「\(note)」") }
            } else if !note.isEmpty {
                parts.append("outfits 留空，prompt 里写明穿着\(note)")
            }
        }
        if on.scenes, let scene = item.scene, !scene.isEmpty {
            parts.append("scene 填「\(scene)」")
        }
        if let situation = item.situation, !situation.isEmpty {
            parts.append("situation 填「\(situation)」")
        }
        if on.props, let props = item.props, !props.isEmpty {
            parts.append("props 可以加「\(props.joined(separator: "、"))」")
        }
        if parts.isEmpty {
            return "生图（image_generate）画她此刻的样子时，地点、穿着和情境以她此刻的状态为准。"
        }
        return "生图（image_generate）画她此刻的样子时：\(parts.joined(separator: "；"))。画别的时间、别的地方就按画面来。"
    }
}

extension String {
    /// "yyyy-MM-dd" → Date（指定时区零点）；解析失败返回 nil
    func toDate(timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: self)
    }
}
