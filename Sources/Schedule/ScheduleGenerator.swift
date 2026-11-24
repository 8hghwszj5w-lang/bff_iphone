import Foundation

// MARK: - 自动日程生成（移植 dsh-daily-schedule 的 generate.js + runner.js + schedule.js 类型部分）
//
// 流程（与桌面插件一致）：
//   1. 按星期从启用的日程类型里加权随机挑一种（上班日/休息日/外出日/宅家日/加班日/摸鱼日）
//   2. 拼 prompt：人设 + 类型框架 + 最近三天摘要（去重提醒）+ 特别要求 + JSON 输出格式；
//      装了生图工作室时附上衣柜 / 常去的地方 / 物品 / 认识的人 / 情境关键词（dress.js wardrobePrompt）
//   3. 调模型拿 JSON → 解析 → normalizeItems（<4 条视为失败）→ linkItems 校验补全穿搭（fill=true）
//   4. 失败 → 类型模板兜底（朴素但完整的一天，同样过一遍 linkItems），并记录错误
// runner 语义：
//   · 今天没有日程（刚装/昨晚关着）→ 打开 App 立刻补上
//   · 到了生成时刻（默认 22:00）明天还没有 → 生成明天的
//   · 失败 20 分钟内不重试（冷却），第二天还没成就由今天的兜底逻辑接手

// MARK: 日程类型（桌面端 store.js DEFAULT_DAY_TYPES）

struct ScheduleDayType: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let weight: Int
    /// 'weekday' / 'weekend' / 'any'
    let days: String
    let guide: String

    static let defaults: [ScheduleDayType] = [
        .init(id: "workday", name: "上班日", weight: 5, days: "weekday",
              guide: "常规上班日，两点一线：起床洗漱、通勤去上班，白天干活（帮用户处理任务、写代码，偶尔偷偷摸鱼），中午吃午饭，傍晚下班通勤回家，晚上吃饭、有一点自己的时间，然后睡觉。"),
        .init(id: "restday", name: "休息日", weight: 4, days: "weekend",
              guide: "不上班，以待在家里为主：睡个懒觉，在家收拾、打游戏或看剧，出门散散步，去附近的餐馆好好吃一顿，晚上在家放松。"),
        .init(id: "outing", name: "外出日", weight: 2, days: "weekend",
              guide: "出门玩一整天：逛街、看展、去公园或海边、找好吃的店，傍晚或晚上才回家，回家时有点累但很满足。"),
        .init(id: "homebody", name: "宅家日", weight: 1, days: "any",
              guide: "哪儿也不想去，几乎一整天窝在家：睡到中午，点外卖，追剧打游戏，作息有点乱，晚上反而精神。工作日遇到这种日子就是请了假。"),
        .init(id: "overtime", name: "加班日", weight: 1, days: "weekday",
              guide: "活多的一天：照常上班，但一直忙到很晚，午饭晚饭都随便对付，回家已经很累，倒头就睡。"),
        .init(id: "slacking", name: "摸鱼日", weight: 1, days: "weekday",
              guide: "名义上在上班，实际上一直找机会摸鱼：开小差、刷手机、去茶水间找零食、假装很忙，但下班前会把要紧的事赶完。"),
    ]
}

// MARK: 生成器

@MainActor
enum ScheduleGenerator {
    /// 每天的自动生成时刻（小时）；到点后打开 App 才会触发（iOS 没有常驻后台定时器）
    static let generateHour = 22
    /// 失败重试冷却（对应桌面端 runner.js RETRY_MS = 20 分钟）
    private static let retryCooldownSeconds: TimeInterval = 20 * 60
    /// 进程内的失败冷却表（dateKey → 何时可以再试）；重启即清空，可接受
    private static var retryAfter: [String: Date] = [:]

    /// 加权随机挑一种类型（对应 schedule.js pickDayType；rand 可注入便于测试）
    static func pickDayType(for date: Date, rand: () -> Double = { Double.random(in: 0..<1) }) -> ScheduleDayType {
        let weekday = Calendar.current.component(.weekday, from: date)   // 1=周日 … 7=周六
        let scope = (weekday == 1 || weekday == 7) ? "weekend" : "weekday"
        let enabled = ScheduleDayType.defaults
        var pool = enabled.filter { ($0.days == scope || $0.days == "any") }
        if pool.isEmpty { pool = enabled }
        if pool.isEmpty {
            return ScheduleDayType.defaults.first { $0.id == "restday" }!
        }
        let total = pool.reduce(0) { $0 + $1.weight }
        var r = rand() * Double(total)
        for type in pool {
            r -= Double(type.weight)
            if r < 0 { return type }
        }
        return pool[pool.count - 1]
    }

    /// 模型生成失败时的兜底：按类型给一份朴素但完整的一天（桌面端 templateItems 移植）
    static func templateItems(type: ScheduleDayType) -> [ScheduleItem] {
        func item(_ start: String, _ end: String, _ activity: String,
                  _ location: String, _ detail: String = "") -> ScheduleItem {
            ScheduleItem(start: start, end: end, activity: activity,
                         location: location, detail: detail.isEmpty ? nil : detail)
        }
        if ["workday", "overtime", "slacking"].contains(type.id) {
            let off = type.id == "overtime" ? "21:00" : "18:00"
            return ScheduleNormalizer.normalize([
                item("00:00", "07:30", "睡觉", "家"),
                item("07:30", "08:15", "起床洗漱、吃早饭", "家"),
                item("08:15", "09:00", "通勤", "路上"),
                item("09:00", "12:00", type.id == "slacking" ? "上班（偷偷摸鱼）" : "上班", "公司"),
                item("12:00", "13:00", "吃午饭", "公司附近"),
                item("13:00", off, type.id == "slacking" ? "上班（继续摸鱼）" : "上班", "公司"),
                item(off, type.id == "overtime" ? "21:45" : "18:45", "下班回家", "路上"),
                item(type.id == "overtime" ? "21:45" : "18:45",
                     type.id == "overtime" ? "22:30" : "19:45", "吃晚饭", "家"),
                item(type.id == "overtime" ? "22:30" : "19:45", "23:00", "自己的时间", "家"),
                item("23:00", "24:00", "睡觉", "家"),
            ])
        }
        if type.id == "outing" {
            return ScheduleNormalizer.normalize([
                item("00:00", "08:30", "睡觉", "家"),
                item("08:30", "10:00", "起床收拾、出门", "家"),
                item("10:00", "12:30", "逛街", "市中心"),
                item("12:30", "14:00", "吃午饭", "餐馆"),
                item("14:00", "17:30", "到处逛逛", "公园"),
                item("17:30", "19:00", "吃晚饭", "餐馆"),
                item("19:00", "20:00", "回家", "路上"),
                item("20:00", "23:30", "在家休息", "家"),
                item("23:30", "24:00", "睡觉", "家"),
            ])
        }
        // restday / homebody
        return ScheduleNormalizer.normalize([
            item("00:00", "09:30", "睡觉", "家"),
            item("09:30", "10:30", "起床、吃早午饭", "家"),
            item("10:30", "13:00", "在家玩", "家"),
            item("13:00", "15:00", "午睡", "家"),
            item("15:00", "16:30", "出门散步", "附近"),
            item("16:30", "18:00", "在家看剧", "家"),
            item("18:00", "19:30", "吃晚饭", type.id == "homebody" ? "家" : "附近的餐馆"),
            item("19:30", "23:30", "自己的时间", "家"),
            item("23:30", "24:00", "睡觉", "家"),
        ])
    }

    /// 保持原顺序去重（桌面端 [...new Set(...)]）
    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// 最近三天摘要（generate.js recentSummary：排除睡觉，列出活动 / 穿过的整套 / 去过的场景）
    private static func recentSummary(store: ScheduleStore, for dateKey: String, days: Int = 3) -> String {
        var lines: [String] = []
        for offset in stride(from: days, through: 1, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset,
                                                   to: dateKey.toDate() ?? Date()),
                  let day = store.loadDay(dateKey: ScheduleStore.dateKey(for: date)) else { continue }
            let main = day.items.filter { !$0.isSleep }.prefix(8)
                .map(\.activity).joined(separator: "、")
            let worn = uniqueOrdered(day.items.compactMap(\.outfit).filter { !$0.isEmpty }).joined(separator: "、")
            let places = uniqueOrdered(day.items.compactMap(\.scene).filter { !$0.isEmpty }).joined(separator: "、")
            var line = "- \(ScheduleStore.dateLabel(for: date))（\(day.dayTypeName ?? "")）：\(day.title ?? "")"
            if !main.isEmpty { line += "。做了：\(main)" }
            if !worn.isEmpty { line += "。穿过：\(worn)" }
            if !places.isEmpty { line += "。去过：\(places)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 拼 prompt（对应 generate.js buildPrompt；装了生图工作室时附上素材库段落）
    static func buildPrompt(characterName: String, persona: String, partnerName: String = "",
                            date: Date, type: ScheduleDayType,
                            recent: String, hint: String,
                            wardrobe: ScheduleWardrobe? = nil, extraRules: String = "") -> String {
        let dateLabel = ScheduleStore.dateLabel(for: date)
        let wardrobeInfo = ScheduleWardrobeLink.wardrobePrompt(wardrobe)
        let situations = (wardrobe?.available == true) ? (wardrobe?.situations.map(\.name) ?? []) : []

        // JSON 示例：睡觉那一段 + 素材库字段（桌面端 generate.js:92）
        var example: [String: Any] = [
            "start": "00:00", "end": "07:30", "activity": "睡觉",
            "location": "家", "detail": "",
        ]
        for (key, value) in wardrobeInfo.example { example[key] = value }
        if !situations.isEmpty { example["situation"] = "睡前" }

        var lines: [String] = [
            "你在为角色「\(characterName)」安排 \(dateLabel) 这一整天的日程。这份日程会作为 \(characterName) 当天的生活背景，聊天时 \(characterName) 会按它知道自己此刻在做什么。",
            persona.isEmpty ? "" : "【人设】\n\(persona)",
            partnerName.isEmpty ? "" : "【用户】\(characterName) 称呼用户为「\(partnerName)」。",
            "【这一天的类型】\(type.name)：\(type.guide.isEmpty ? "按这个类型合理安排。" : type.guide)",
            recent.isEmpty ? "" : "【最近几天】\n\(recent)\n这一天的安排、小插曲和穿搭不要和最近几天重复。",
            wardrobeInfo.sections,
            extraRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : "【固定设定】\(extraRules.trimmingCharacters(in: .whitespacesAndNewlines))",
            hint.isEmpty ? "" : "【这一天的特别要求（优先满足）】\(hint)",
            "【要求】",
            "- 从 00:00 排到 24:00，时间连续、不重叠，24 小时制 HH:MM，最后一段的 end 写 24:00；一般 12–20 段。",
            "- 每段：activity 写在做什么（具体，10 字以内，例如「挤地铁去公司」「在茶水间偷吃饼干」）；location 写在哪；detail 写一两句当时的状态或小插曲（心情、吃了什么、碰到什么事、和谁在一起），让这一天有活人感。",
            "- 符合人设的性格和习惯，但别夸张成闹剧；睡觉时间合理。",
            situations.isEmpty ? "" : "- situation：从这些情境里挑最贴近的一个（\(situations.joined(separator: "、"))），都不贴近就留空。",
        ]
        lines.append(contentsOf: wardrobeInfo.rules)
        lines.append("只输出一个 JSON 对象：title 是这一天的标题，mood 是当天心情，items 是按时间排列的完整日程数组。下面只展示第一段的格式，实际请在 items 中续写到 24:00，不要输出其他文字或代码块标记：")
        lines.append(Self.jsonString(["title": "平稳的一天", "mood": "轻松", "items": [example]]))
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 解析模型输出（generate.js parseSchedule 移植：剥代码块围栏、取首尾大括号、
    /// normalize 后不足 4 条视为失败；scene / situation / outfit / outfitNote / props / with 一并解析）
    static func parseSchedule(_ text: String) throws -> (title: String, mood: String, items: [ScheduleItem]) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else {
            throw NSError(domain: "ScheduleGen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "模型没有返回 JSON：\(s.prefix(120))"])
        }
        let json = String(s[a...b])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "ScheduleGen", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "日程 JSON 解析失败"])
        }
        guard let entries = obj["items"] as? [[String: Any]] else {
            throw NSError(domain: "ScheduleGen", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "模型返回的日程缺少有效的 items 数组"])
        }
        let rawItems = entries.compactMap(Self.item(from:))
        let items = ScheduleNormalizer.normalize(rawItems)
        guard items.count >= 4 else {
            throw NSError(domain: "ScheduleGen", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "模型给的日程太短了"])
        }
        let title = ScheduleItem.oneLine(obj["title"] as? String, 80)
        let mood = ScheduleItem.oneLine(obj["mood"] as? String, 40)
        return (title, mood, items)
    }

    /// 模型 JSON 的一段 → ScheduleItem（兼容 outfit_note 等桌面端字段名）
    private static func item(from raw: [String: Any]) -> ScheduleItem? {
        guard let start = raw["start"] as? String,
              let end = raw["end"] as? String,
              let activity = raw["activity"] as? String else { return nil }
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = raw[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            }
            return nil
        }
        func list(_ keys: [String]) -> [String]? {
            for key in keys {
                if let values = raw[key] as? [String] { return values }
                if let value = raw[key] as? String, !value.isEmpty { return [value] }
            }
            return nil
        }
        return ScheduleItem(start: start, end: end, activity: activity,
                            location: string(["location"]), detail: string(["detail"]),
                            outfit: string(["outfit"]),
                            outfitNote: string(["outfitNote", "outfit_note"]),
                            scene: string(["scene"]), situation: string(["situation"]),
                            props: list(["props"]), with: list(["with"]))
    }

    /// 生成并保存某一天的日程。永不抛错：失败时用类型模板兜底并记录错误。
    /// - Parameters:
    ///   - ask: 传一句 prompt 给 LLM 拿全文。生产侧用 DeepSeekClient 包装；测试注入假实现
    ///   - dayTypeId: 指定类型（UI「按要求重新生成」用）；nil = 加权随机
    ///   - hint: 这一天的特别要求（如「下午和你去看电影」）
    ///   - fallback: false 时不兜底、直接抛错（供诊断与 autoFill 冷却）
    ///   - wardrobe: 生图工作室素材库快照（nil = 按无素材库降级，只按文字生成）
    ///   - partnerName / extraRules: 对应桌面端 cfg.partnerName / cfg.extraRules（【用户】【固定设定】段落）
    static func generateDay(dateKey: String, persona: String, characterName: String,
                            client ask: @Sendable (String) async throws -> String,
                            store: ScheduleStore, dayTypeId: String? = nil,
                            hint: String? = nil, fallback: Bool = true,
                            wardrobe: ScheduleWardrobe? = nil,
                            partnerName: String = "", extraRules: String = "") async throws -> DaySchedule {
        let date = dateKey.toDate() ?? Date()
        // 指定类型强制生效（UI 下拉框）；nil 才走加权随机
        let type = dayTypeId.flatMap { id in ScheduleDayType.defaults.first { $0.id == id } }
            ?? pickDayType(for: date)
        let prompt = buildPrompt(characterName: characterName, persona: String(persona.prefix(3500)),
                                 partnerName: partnerName, date: date, type: type,
                                 recent: recentSummary(store: store, for: dateKey),
                                 hint: (hint ?? "").trimmingCharacters(in: .whitespaces),
                                 wardrobe: wardrobe, extraRules: extraRules)
        var day = DaySchedule(date: dateKey, dayTypeName: type.name)
        day.generatedAt = Date()
        do {
            let text = try await ask(prompt)
            let parsed = try parseSchedule(text)
            day.title = parsed.title
            day.mood = parsed.mood
            // 生成后按素材库校验名字并补全穿搭 / 场景（桌面端 generate.js:163 linkItems(..., {fill:true})）
            day.items = ScheduleWardrobeLink.linkItems(parsed.items, wardrobe: wardrobe, fill: true)
            day.source = "llm"
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard fallback else { throw error }
            day.title = type.name
            day.items = ScheduleWardrobeLink.linkItems(templateItems(type: type), wardrobe: wardrobe, fill: true)
            day.source = "template"
            day.generationError = "\(error.localizedDescription)"
        }
        store.saveDay(day)
        return day
    }

    // MARK: 自动补齐（runner.js 的 iOS 移植：没有常驻后台，App 在前台时按需触发）

    /// 1）今天没有日程 → 立刻补上；2）到了生成时刻明天还没有 → 生成明天的。
    /// 失败 20 分钟内不重试同一日期。返回实际生成的日期 key 列表。
    /// - Parameter wardrobe: 生图工作室素材库快照（Lead 在 AppState 里接 wardrobeProvider）
    @discardableResult
    static func autoFill(store: ScheduleStore, persona: String, characterName: String,
                         wardrobe: ScheduleWardrobe? = nil,
                         ask: @escaping @Sendable (String) async throws -> String,
                         now: Date = Date()) async -> [String] {
        var generated: [String] = []
        let todayKey = ScheduleStore.dateKey(for: now)
        guard let tomorrowKey = ScheduleStore.dayKey(for: "tomorrow", now: now) else { return generated }

        // 1. 今天没有（刚装 / 昨晚没生成）→ 马上补；补完继续走下面的明天分支
        if store.loadDay(dateKey: todayKey) == nil {
            do {
                _ = try await generateDay(dateKey: todayKey, persona: persona,
                                          characterName: characterName, client: ask, store: store,
                                          wardrobe: wardrobe)
                retryAfter.removeValue(forKey: todayKey)
                generated.append(todayKey)
            } catch {
                // 今天失败多半是网络问题：明天同样进冷却，等下次触发再试
                //（冷却以注入的 now 为基准，纯函数语义便于测试）
                retryAfter[tomorrowKey] = now.addingTimeInterval(retryCooldownSeconds)
                return generated
            }
        }

        // 2. 到了生成时刻且明天还没有 → 生成明天的
        let minuteOfDay = Calendar.current.component(.hour, from: now) * 60
            + Calendar.current.component(.minute, from: now)
        let due = generateHour * 60
        guard minuteOfDay >= due, store.loadDay(dateKey: tomorrowKey) == nil else { return generated }
        if let retry = retryAfter[tomorrowKey], retry > now { return generated }   // 冷却中

        do {
            _ = try await generateDay(dateKey: tomorrowKey, persona: persona,
                                      characterName: characterName, client: ask, store: store,
                                      fallback: false,   // 显式失败 → 进冷却，不拿模板占坑
                                      wardrobe: wardrobe)
            generated.append(tomorrowKey)
            retryAfter.removeValue(forKey: tomorrowKey)
        } catch {
            retryAfter[tomorrowKey] = now.addingTimeInterval(retryCooldownSeconds)
        }
        return generated
    }

    /// 测试辅助：清空进程内冷却表（生产代码不要调）
    static func clearRetryCooldowns() {
        retryAfter.removeAll()
    }
}
