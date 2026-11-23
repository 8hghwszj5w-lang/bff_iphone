import Foundation

// MARK: - 每日日程数据模型（移植 DSH 插件 dsh-daily-schedule 的 schedule.js）
//
// 一天的日程形状（与桌面端插件同构）：
//   { date: "yyyy-MM-dd", dayTypeName?, title?, mood?,
//     items: [{ start: "HH:MM", end: "HH:MM", activity, location?, detail?,
//               scene?, situation?, outfit?, outfitNote?, props?, with? }],
//     changes: [{ at, note }] }
// items 经过 normalize 保证：排序、不重叠、从 00:00 连续覆盖到 24:00、至多 40 条。
// end 允许 "24:00"；桌面端模型偶发写 "00:00" 时由 cleaned() 归一到 24:00。

struct ScheduleItem: Codable, Equatable {
    var start: String        // "HH:MM"（end 允许 "24:00"）
    var end: String
    var activity: String
    var location: String?
    var detail: String?
    /// 这一段穿什么（服饰库名字，可不在库里）——生图时沿用（对应桌面端 daily-schedule 的 outfit 字段）
    var outfit: String?
    /// 穿搭细节补充（如「外面套了件米色开衫」）——写进生图提示词
    var outfitNote: String?
    /// 地点对应的生图场景库条目名（桌面端 schedule.js 的 scene 字段）
    var scene: String?
    /// 这段对应的生图情境关键词（桌面端 schedule.js 的 situation 字段）
    var situation: String?
    /// 手边的物品（道具库名字，最多 4 个；桌面端 schedule.js 的 props 字段）
    var props: [String]?
    /// 和谁在一起（人物库里的其他人；桌面端 schedule.js 的 with 字段）
    var with: [String]?

    init(start: String, end: String, activity: String,
         location: String? = nil, detail: String? = nil,
         outfit: String? = nil, outfitNote: String? = nil,
         scene: String? = nil, situation: String? = nil,
         props: [String]? = nil, with: [String]? = nil) {
        self.start = start
        self.end = end
        self.activity = activity
        self.location = location
        self.detail = detail
        self.outfit = outfit
        self.outfitNote = outfitNote
        self.scene = scene
        self.situation = situation
        self.props = props
        self.with = with
    }

    // MARK: 解码兼容（旧 iOS JSON / 桌面端 JSON 都能读）

    private enum CodingKeys: String, CodingKey {
        case start, end, activity, location, detail
        case outfit, outfitNote, scene, situation, props, with
        /// 桌面端 schedule_adjust / 生图补搭写的是 snake_case
        case outfitNoteSnake = "outfit_note"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = (try? c.decode(String.self, forKey: .start)) ?? ""
        end = (try? c.decode(String.self, forKey: .end)) ?? ""
        activity = (try? c.decode(String.self, forKey: .activity)) ?? ""
        location = Self.decodeOptionalString(c, .location)
        detail = Self.decodeOptionalString(c, .detail)
        outfit = Self.decodeOptionalString(c, .outfit)
        outfitNote = Self.decodeOptionalString(c, .outfitNote) ?? Self.decodeOptionalString(c, .outfitNoteSnake)
        scene = Self.decodeOptionalString(c, .scene)
        situation = Self.decodeOptionalString(c, .situation)
        props = Self.decodeStringList(c, .props)
        with = Self.decodeStringList(c, .with)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(activity, forKey: .activity)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(outfit, forKey: .outfit)
        try c.encodeIfPresent(outfitNote, forKey: .outfitNote)
        try c.encodeIfPresent(scene, forKey: .scene)
        try c.encodeIfPresent(situation, forKey: .situation)
        try c.encodeIfPresent(props, forKey: .props)
        try c.encodeIfPresent(with, forKey: .with)
    }

    private static func decodeOptionalString(_ c: KeyedDecodingContainer<CodingKeys>,
                                             _ key: CodingKeys) -> String? {
        guard let value = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return value
    }

    /// 桌面端 props/with 允许字符串或字符串数组；数字等脏值忽略
    private static func decodeStringList(_ c: KeyedDecodingContainer<CodingKeys>,
                                        _ key: CodingKeys) -> [String]? {
        if let list = try? c.decodeIfPresent([String].self, forKey: key) { return list }
        if let single = try? c.decodeIfPresent(String.self, forKey: key) { return single.isEmpty ? nil : [single] }
        return nil
    }

    // MARK: 派生属性

    var startMinute: Int { Self.minutes(of: start) ?? 0 }
    var endMinute: Int { Self.minutes(of: end) ?? 1440 }
    var isSleep: Bool { activity.contains("睡") }

    /// 地点标签：桌面端 inject.js placeOf 是 scene || location（场景库名字优先）
    var placeLabel: String {
        if let scene, !scene.isEmpty { return "（\(scene)）" }
        if let location, !location.isEmpty { return "（\(location)）" }
        return ""
    }

    /// 穿着标签（对应桌面端 dress.js outfitLabel）：
    /// 衣柜里的名字 + 细节备注 → 「居家针织服」（外面加了件开衫）
    var outfitLabel: String {
        let name = (outfit ?? "").trimmingCharacters(in: .whitespaces)
        let note = (outfitNote ?? "").trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !note.isEmpty { return "「\(name)」（\(note)）" }
        if !name.isEmpty { return "「\(name)」" }
        return note
    }

    // MARK: 清洗（对应桌面端 schedule.js cleanItem）

    /// 折叠空白、按上限截断（桌面端 `String(v).replace(/\s+/g, ' ').trim().slice(0, max)`）
    static func oneLine(_ value: String?, _ max: Int) -> String {
        let collapsed = (value ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > max ? String(collapsed.prefix(max)) : collapsed
    }

    /// 同 oneLine，但截断时带省略号（桌面端 dress.js 的 oneLine，用于提示词里的一句话简介）
    static func oneLineEllipsis(_ value: String?, _ max: Int) -> String {
        let collapsed = (value ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > max ? "\(collapsed.prefix(max))…" : collapsed
    }

    static func optionalText(_ value: String?, _ max: Int) -> String? {
        let text = oneLine(value, max)
        return text.isEmpty ? nil : text
    }

    /// 列表清洗：去空白、截断、限量（桌面端 `list()`：activity 40 / 最多 4 条）
    static func textList(_ values: [String]?, limit: Int) -> [String]? {
        let out = (values ?? []).map { oneLine($0, 40) }.filter { !$0.isEmpty }.prefix(limit)
        return out.isEmpty ? nil : Array(out)
    }

    /// 桌面端 cleanItem 的移植：非法时间 / 空活动返回 nil（normalize 时丢弃）；
    /// end "00:00" 在 start > 0 时归一为 "24:00"；所有文本折叠空白并按上限截断。
    func cleaned() -> ScheduleItem? {
        guard let s = Self.minutes(of: start), let rawEnd = Self.minutes(of: end) else { return nil }
        let activity = Self.oneLine(activity, 40)
        guard !activity.isEmpty else { return nil }
        var item = self
        item.start = Self.clock(minutes: s)
        item.end = Self.clock(minutes: rawEnd == 0 && s > 0 ? 1440 : rawEnd)
        item.activity = activity
        item.location = Self.optionalText(location, 30)
        item.detail = Self.optionalText(detail, 240)
        item.situation = Self.optionalText(situation, 20)
        item.scene = Self.optionalText(scene, 40)
        item.outfit = Self.optionalText(outfit, 40)
        item.outfitNote = Self.optionalText(outfitNote, 60)
        item.props = Self.textList(props, limit: 4)
        item.with = Self.textList(with, limit: 4)
        return item
    }

    static func minutes(of clock: String) -> Int? {
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0...59).contains(m), h < 24 || m == 0 else { return nil }
        return h * 60 + m
    }

    static func clock(minutes: Int) -> String {
        let clamped = min(1440, max(0, minutes))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

// MARK: - 生图工作室素材库给日程用的快照（对应桌面端 wardrobe.js 读 image-studio 的库与 presets）
//
// 桌面端日程插件直接读生图插件的 library/ 与 presets.json；iOS 两个 Store 之间不直接互相持有，
// 由 AppState 把 ImageStudioStore 的快照闭包接进 ScheduleStore.wardrobeProvider，保持单向依赖。
// 联动开关对应桌面端 link.outfits / link.scenes / link.props / link.people。

/// 素材库里的一条（人物 / 服饰 / 场景 / 道具通用）
struct ScheduleWardrobeItem: Equatable {
    var name: String
    var aliases: [String] = []
    var tags: [String] = []
    var descriptionText: String = ""
    /// 默认服饰（人物：平时穿；场景：在这个场景里默认穿）
    var defaultOutfit: String = ""
}

/// 情境关键词（来自生图工作室的 presets.situation）
struct ScheduleWardrobeSituation: Equatable {
    var name: String
    var aliases: [String] = []
    /// 这个情境默认的场景 / 服饰（库里没有时为 nil）
    var scene: String = ""
    var outfit: String = ""
}

/// 生图工作室素材库快照
struct ScheduleWardrobe: Equatable {
    /// 她的人物条目名（生图时 characters 填它）
    var herName: String = ""
    var herDefaultOutfit: String = ""
    /// 她各情境下的专属穿搭：情境名 → 服饰名
    var herSituationOutfits: [String: String] = [:]
    var outfits: [ScheduleWardrobeItem] = []
    var scenes: [ScheduleWardrobeItem] = []
    var props: [ScheduleWardrobeItem] = []
    /// 人物库里除她以外的人
    var people: [ScheduleWardrobeItem] = []
    var situations: [ScheduleWardrobeSituation] = []
    var outfitsOn: Bool = true
    var scenesOn: Bool = true
    var propsOn: Bool = true
    var peopleOn: Bool = true

    /// 素材库是否可用（生图工作室装了且素材库非空）
    var available: Bool {
        !outfits.isEmpty || !scenes.isEmpty || !props.isEmpty || !people.isEmpty || !situations.isEmpty
    }
}

// MARK: - 素材库联动（移植桌面端 dress.js / wardrobe.js 的纯函数部分）
//
// 规则（和生图插件选服饰的顺序一致）：
//   模型给的 > 延续上一段 > 她在这个情境的专属穿搭 > 情境默认 > 场景默认 > 她的默认服饰

enum ScheduleWardrobeLink {
    /// 桌面端 linkOn(cfg)：四个联动开关（iOS 由生图工作室的配置快照带过来）
    struct LinkOn: Equatable {
        var outfits: Bool
        var scenes: Bool
        var props: Bool
        var people: Bool
    }

    static func linkOn(_ wardrobe: ScheduleWardrobe) -> LinkOn {
        LinkOn(outfits: wardrobe.outfitsOn, scenes: wardrobe.scenesOn,
               props: wardrobe.propsOn, people: wardrobe.peopleOn)
    }

    // MARK: 名字匹配（对应 wardrobe.js norm / resolveEntry / findSituation）

    static func norm(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    /// 按名字 / 别名找条目；再退一步找唯一的包含匹配（和生图插件同一套规则）
    static func resolve(_ list: [ScheduleWardrobeItem], _ ref: String?) -> ScheduleWardrobeItem? {
        let key = norm(ref)
        guard !key.isEmpty else { return nil }
        if let exact = list.first(where: { norm($0.name) == key }) { return exact }
        if let alias = list.first(where: { $0.aliases.contains { norm($0) == key } }) { return alias }
        let loose = list.filter { item in
            ([item.name] + item.aliases).contains { name in
                let nn = norm(name)
                return nn.count >= 2 && (key.contains(nn) || nn.contains(key))
            }
        }
        return loose.count == 1 ? loose[0] : nil
    }

    static func findSituation(_ wardrobe: ScheduleWardrobe, _ ref: String?) -> ScheduleWardrobeSituation? {
        let key = norm(ref)
        guard !key.isEmpty else { return nil }
        if let exact = wardrobe.situations.first(where: { norm($0.name) == key }) { return exact }
        return wardrobe.situations.first { $0.aliases.contains { norm($0) == key } }
    }

    // MARK: 生成提示词（对应 dress.js habitLines / wardrobePrompt）

    private static func entryLabel(_ entry: ScheduleWardrobeItem) -> String {
        let aliases = entry.aliases.prefix(2).joined(separator: "/")
        return aliases.isEmpty ? entry.name : "\(entry.name)（又名 \(aliases)）"
    }

    private static func entryBrief(_ entry: ScheduleWardrobeItem, max: Int) -> String {
        var parts: [String] = []
        if !entry.tags.isEmpty { parts.append(entry.tags.prefix(5).joined(separator: "、")) }
        if !entry.descriptionText.isEmpty { parts.append(ScheduleItem.oneLineEllipsis(entry.descriptionText, max)) }
        return parts.isEmpty ? "" : "：\(parts.joined(separator: "；"))"
    }

    /// 她平时的穿搭习惯（情境 → 服饰、场景 → 服饰、默认）
    static func habitLines(_ wardrobe: ScheduleWardrobe) -> [String] {
        var lines: [String] = []
        for situation in wardrobe.situations {
            let own = wardrobe.herSituationOutfits[situation.name] ?? ""
            let outfit = own.isEmpty ? situation.outfit : own
            if !outfit.isEmpty { lines.append("\(situation.name)→\(outfit)") }
        }
        for scene in wardrobe.scenes where !scene.defaultOutfit.isEmpty {
            lines.append("在\(scene.name)→\(scene.defaultOutfit)")
        }
        if !wardrobe.herDefaultOutfit.isEmpty { lines.append("平时→\(wardrobe.herDefaultOutfit)") }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    /// 生成提示词里关于衣柜 / 场景 / 物品 / 人物的部分
    struct PromptParts {
        var sections: String = ""
        var rules: [String] = []
        /// 写进 JSON 示例的字段（outfit / outfit_note / scene / props / with）
        var example: [String: Any] = [:]
    }

    static func wardrobePrompt(_ wardrobe: ScheduleWardrobe?) -> PromptParts {
        var parts = PromptParts()
        guard let wardrobe, wardrobe.available else { return parts }
        let on = linkOn(wardrobe)
        guard on.outfits || on.scenes || on.props || on.people else { return parts }
        var sections: [String] = []
        var rules: [String] = []

        if on.outfits && !wardrobe.outfits.isEmpty {
            let list = wardrobe.outfits.prefix(30)
                .map { "- \(entryLabel($0))\(entryBrief($0, max: 70))" }.joined(separator: "\n")
            sections.append("【她的衣柜】（生图工作室的服饰库，每段的 outfit 从这里选，写名字）\n\(list)")
            let habits = habitLines(wardrobe)
            if !habits.isEmpty { sections.append("【她平时的穿搭习惯】\(habits.joined(separator: "；"))") }
            rules.append("- outfit：这一段穿着衣柜里的哪一套，写名字。穿搭要连续，只在合理的时候换（起床后、出门前、回到家、洗完澡、睡前），同一套可以连着很多段；按场合和天气挑，别一整天都同一套也别频繁乱换。衣柜里没有合适的（比如睡衣、泳衣、运动服），outfit 留空、在 outfit_note 写穿着什么；在衣柜那套的基础上有变化（加了件外套、系着围裙、换了双鞋），也写在 outfit_note。")
            // 示例用睡觉那一段：衣柜里有睡衣就写它，没有就示范 outfit_note
            let pajama = wardrobe.outfits.first { entry in
                ([entry.name] + entry.aliases + entry.tags).contains {
                    $0.range(of: "睡衣|睡裙|pajama", options: [.regularExpression, .caseInsensitive]) != nil
                }
            }
            parts.example["outfit"] = pajama?.name ?? ""
            parts.example["outfit_note"] = pajama == nil ? "睡衣" : ""
        }
        if on.scenes && !wardrobe.scenes.isEmpty {
            let list = wardrobe.scenes.prefix(20)
                .map { "- \(entryLabel($0))\(entryBrief($0, max: 70))" }.joined(separator: "\n")
            sections.append("【常去的地方】（场景库，地点就是这里时 scene 填名字）\n\(list)")
            rules.append("- scene：地点就是上面某个场景时填它的名字。在家时尽量落在库里有的房间；出门时可以多去库里有的地方，也可以去新地方——库里没有的地点 scene 留空，照常写 location。")
            let bedroom = wardrobe.scenes.first { entry in
                ([entry.name] + entry.aliases + entry.tags).contains {
                    $0.range(of: "卧室|房间|睡觉|bedroom", options: [.regularExpression, .caseInsensitive]) != nil
                }
            }
            parts.example["scene"] = bedroom?.name ?? ""
        }
        if on.props && !wardrobe.props.isEmpty {
            let list = wardrobe.props.prefix(20)
                .map { "- \(entryLabel($0))\(entryBrief($0, max: 40))" }.joined(separator: "\n")
            sections.append("【她的物品】（道具库，用到时 props 填名字）\n\(list)")
            rules.append("- props：这一段用到物品库里的东西时填名字，最多 2 个，没有就留空数组。")
            parts.example["props"] = [String]()
        }
        if on.people && !wardrobe.people.isEmpty {
            let list = wardrobe.people.prefix(10)
                .map { "- \(entryLabel($0))\(entryBrief($0, max: 50))" }.joined(separator: "\n")
            sections.append("【认识的人】（人物库里的其他角色）\n\(list)")
            rules.append("- with：和上面认识的人在一起时填名字，没有就留空数组。别硬凑，大部分时候她是一个人或和用户在一起。")
            parts.example["with"] = [String]()
        }
        parts.sections = sections.joined(separator: "\n")
        parts.rules = rules
        return parts
    }

    // MARK: 校验与补全（对应 dress.js linkItems）

    private static let situationGuesses: [(String, [String])] = [
        ("睡觉|入睡|睡着|午睡", ["睡前"]),
        ("起床|赖床|醒", ["刚睡醒"]),
        ("上班|工作|写代码|开会|干活|加班|摸鱼", ["工作学习"]),
        ("出门|逛|散步|约会|看展|公园|海边|外出|旅行|咖啡", ["外出"]),
        ("吃|饭|外卖|零食|夜宵|下午茶", ["吃东西"]),
        ("沙发|电视|看剧|看番|综艺|电影", ["客厅放松"]),
        ("游戏|追剧|刷手机|发呆|休息|宅", ["在家休息"]),
    ]

    static func guessSituation(_ item: ScheduleItem, _ wardrobe: ScheduleWardrobe) -> ScheduleWardrobeSituation? {
        if let situation = item.situation, let found = findSituation(wardrobe, situation) { return found }
        let hay = "\(item.activity) \(item.location ?? "")"
        for (pattern, names) in situationGuesses {
            guard hay.range(of: pattern, options: .regularExpression) != nil else { continue }
            for name in names {
                if let found = findSituation(wardrobe, name) { return found }
            }
        }
        return nil
    }

    /// 地点里「家」「-」这类前缀去掉后剩下的具体位置：「家-厨房」→「厨房」，「家」→ ''
    static func placeCore(_ location: String?) -> String {
        let cleaned = (location ?? "").replacingOccurrences(
            of: "[\\s\\-—–·・/|，,、（）()的]+", with: " ", options: .regularExpression)
        return cleaned.split(separator: " ")
            .map { token -> String in
                String(token).replacingOccurrences(
                    of: "^(在|我|她|自己)?(家|家里|屋里|房间里|公寓)?(的|里)?",
                    with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 按地点文字认场景：库里的名字出现在地点里，或地点（去掉「家-」）是某个场景名字的一部分
    static func sceneFromLocation(_ item: ScheduleItem, _ wardrobe: ScheduleWardrobe) -> ScheduleWardrobeItem? {
        let location = item.location ?? ""
        guard !location.isEmpty else { return nil }
        func names(_ entry: ScheduleWardrobeItem) -> [String] {
            ([entry.name] + entry.aliases).filter { $0.count >= 2 }
        }
        var hits = wardrobe.scenes.filter { names($0).contains { location.contains($0) } }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 { return nil }
        let parts = placeCore(location).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        hits = wardrobe.scenes.filter { entry in names(entry).contains { name in parts.contains { name.contains($0) } } }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 地点只说了「家」「家里」，没说哪个房间
    static func genericHome(_ location: String?) -> Bool {
        let text = (location ?? "").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return true }
        guard text.range(of: "家|屋|房|公寓", options: .regularExpression) != nil else { return false }
        return placeCore(text).isEmpty
    }

    /// 这一段按规则该穿哪套（她的情境穿搭 > 情境默认 > 场景默认 > 她的默认服饰）
    private static func ruleOutfit(_ item: ScheduleItem, _ wardrobe: ScheduleWardrobe) -> String {
        let situation = guessSituation(item, wardrobe)
        let sceneEntry = item.scene.flatMap { resolve(wardrobe.scenes, $0) }
        let candidates: [String] = [
            situation.flatMap { wardrobe.herSituationOutfits[$0.name] } ?? "",
            situation?.outfit ?? "",
            sceneEntry?.defaultOutfit ?? "",
            wardrobe.herDefaultOutfit,
        ]
        for candidate in candidates where !candidate.isEmpty {
            if let resolved = resolve(wardrobe.outfits, candidate) { return resolved.name }
        }
        return ""
    }

    /// 把模型给的穿搭 / 场景 / 物品 / 人物对上库里的名字，缺的按规则补。
    /// - Parameter fill: true = 缺的补上（生成 / 补穿搭用）；false = 只校验名字（schedule_adjust 用）
    static func linkItems(_ items: [ScheduleItem], wardrobe: ScheduleWardrobe?, fill: Bool) -> [ScheduleItem] {
        guard let wardrobe, wardrobe.available else { return items }
        let on = linkOn(wardrobe)
        var out: [ScheduleItem] = []
        var previous: ScheduleItem?
        var previousRule = ""
        for raw in items {
            var item = raw
            // 场景：对上库里的正名；没给的按地点文字认
            if on.scenes {
                let given = item.scene.flatMap { resolve(wardrobe.scenes, $0) }
                if given == nil, let scene = item.scene, !scene.isEmpty,
                   (item.location ?? "").isEmpty {
                    item.location = scene     // 只写了场景名、没写地点：拿它当地点文字
                }
                item.scene = given?.name
                if item.scene == nil, fill {
                    if let byLocation = sceneFromLocation(item, wardrobe) {
                        item.scene = byLocation.name
                    } else if let situation = guessSituation(item, wardrobe),
                              !situation.scene.isEmpty,
                              genericHome(item.location),
                              let scene = resolve(wardrobe.scenes, situation.scene) {
                        item.scene = scene.name
                    }
                }
            }
            // 服饰：库里的名字留在 outfit，库里没有的转进 outfitNote；缺的按规则补
            if on.outfits {
                let given = (item.outfit ?? "").trimmingCharacters(in: .whitespaces)
                let note = (item.outfitNote ?? "").trimmingCharacters(in: .whitespaces)
                let hit = given.isEmpty ? nil : resolve(wardrobe.outfits, given)
                item.outfit = hit?.name
                let mergedNote = [hit == nil ? given : "", note].filter { !$0.isEmpty }.joined(separator: "，")
                item.outfitNote = mergedNote.isEmpty ? nil : mergedNote
                let rule = fill ? ruleOutfit(item, wardrobe) : ""
                if fill, (item.outfit ?? "").isEmpty, (item.outfitNote ?? "").isEmpty {
                    let previousHasOutfit = !(previous?.outfit ?? "").isEmpty || !(previous?.outfitNote ?? "").isEmpty
                    if let previous, previousHasOutfit, rule.isEmpty || rule == previousRule {
                        item.outfit = previous.outfit
                        item.outfitNote = previous.outfitNote
                    } else if !rule.isEmpty {
                        item.outfit = rule
                    }
                }
                previousRule = rule
            }
            if on.props {
                var seen = Set<String>()
                item.props = (item.props ?? [])
                    .compactMap { resolve(wardrobe.props, $0)?.name }
                    .filter { seen.insert($0).inserted }
                    .prefix(3).map { $0 }
            }
            if on.people {
                var seen = Set<String>()
                item.with = (item.with ?? [])
                    .compactMap { resolve(wardrobe.people, $0)?.name }
                    .filter { seen.insert($0).inserted }
                    .prefix(4).map { $0 }
            }
            // 关掉的联动：生成时模型没被要求写这些，顺手写了也不要
            if fill {
                if !on.outfits { item.outfit = nil; item.outfitNote = nil }
                if !on.scenes { item.scene = nil }
                if !on.props { item.props = nil }
                if !on.people { item.with = nil }
            }
            // 空值统一删掉（对应桌面端 delete it.outfit / it.props 收尾）
            if item.outfit?.isEmpty ?? true { item.outfit = nil }
            if item.outfitNote?.isEmpty ?? true { item.outfitNote = nil }
            if item.scene?.isEmpty ?? true { item.scene = nil }
            if item.props?.isEmpty ?? true { item.props = nil }
            if item.with?.isEmpty ?? true { item.with = nil }
            out.append(item)
            previous = item
        }
        return out
    }
}

// MARK: - 换装时间线（对应桌面端 dress.js outfitRuns / runText）

struct ScheduleOutfitRun: Equatable {
    var start: String
    var end: String
    var label: String
    var outfit: String
    var note: String
}

enum ScheduleOutfit {
    /// 一天的换装：[run]，相邻相同的合并
    static func runs(_ items: [ScheduleItem]) -> [ScheduleOutfitRun] {
        var runs: [ScheduleOutfitRun] = []
        for item in items {
            let label = item.outfitLabel
            guard !label.isEmpty else { continue }
            if var last = runs.last, last.label == label, last.end == item.start {
                last.end = item.end
                runs[runs.count - 1] = last
            } else {
                runs.append(ScheduleOutfitRun(start: item.start, end: item.end, label: label,
                                              outfit: item.outfit ?? "", note: item.outfitNote ?? ""))
            }
        }
        return runs
    }

    /// 「睡衣 → 09:00 起「居家针织服」」（桌面端 inject.js runText）
    static func text(_ runs: [ScheduleOutfitRun]) -> String {
        runs.enumerated()
            .map { index, run in index == 0 ? run.label : "\(run.start) 起\(run.label)" }
            .joined(separator: " → ")
    }
}

// MARK: - 临时改动记录

struct ScheduleChange: Codable, Equatable {
    var at: Date
    var note: String

    init(at: Date, note: String) {
        self.at = at
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case at, note }

    /// 桌面端写的是 ISO 字符串、旧 iOS 写的是数字时间戳，两种都认
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let date = try? c.decode(Date.self, forKey: .at) {
            at = date
        } else if let text = try? c.decode(String.self, forKey: .at),
                  let date = ScheduleJSONDate.parse(text) {
            at = date
        } else {
            at = Date(timeIntervalSince1970: 0)
        }
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

// MARK: - 一天

struct DaySchedule: Codable, Equatable {
    var date: String                 // yyyy-MM-dd
    var dayTypeName: String? = nil   // 上班日 / 休息日 / 外出日…
    var title: String? = nil
    var mood: String? = nil
    var items: [ScheduleItem] = []
    var changes: [ScheduleChange]? = nil
    /// "llm"（模型生成）/"template"（失败兜底模板）/"manual"（手编辑）
    var source: String? = nil
    var generationError: String? = nil
    var generatedAt: Date? = nil

    init(date: String, dayTypeName: String? = nil, title: String? = nil, mood: String? = nil,
         items: [ScheduleItem] = [], changes: [ScheduleChange]? = nil,
         source: String? = nil, generationError: String? = nil, generatedAt: Date? = nil) {
        self.date = date
        self.dayTypeName = dayTypeName
        self.title = title
        self.mood = mood
        self.items = items
        self.changes = changes
        self.source = source
        self.generationError = generationError
        self.generatedAt = generatedAt
    }

    func findItem(atMinute minute: Int) -> Int {
        items.firstIndex { minute >= $0.startMinute && minute < $0.endMinute } ?? -1
    }

    // MARK: 解码兼容（旧 iOS JSON / 桌面端 JSON）

    private enum CodingKeys: String, CodingKey {
        case date, dayTypeName, title, mood, items, changes
        case source, generationError, generatedAt
    }

    /// 只用于读取桌面端字段，不参与 iOS 存档的自动编码。
    private enum DesktopKeys: String, CodingKey {
        case dayType, error
    }

    private struct DayTypeBox: Decodable {
        var name: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let desktop = try decoder.container(keyedBy: DesktopKeys.self)
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        title = try? c.decode(String.self, forKey: .title)
        mood = try? c.decode(String.self, forKey: .mood)
        items = (try? c.decode([ScheduleItem].self, forKey: .items)) ?? []
        changes = try? c.decode([ScheduleChange].self, forKey: .changes)
        source = try? c.decode(String.self, forKey: .source)
        if let name = try? c.decode(String.self, forKey: .dayTypeName) {
            dayTypeName = name
        } else if let box = try? desktop.decode(DayTypeBox.self, forKey: .dayType) {
            dayTypeName = box.name
        } else {
            dayTypeName = nil
        }
        if let message = try? c.decode(String.self, forKey: .generationError) {
            generationError = message
        } else if let message = try? desktop.decode(String.self, forKey: .error) {
            generationError = message
        } else {
            generationError = nil
        }
        if let date = try? c.decode(Date.self, forKey: .generatedAt) {
            generatedAt = date
        } else if let text = try? c.decode(String.self, forKey: .generatedAt) {
            generatedAt = ScheduleJSONDate.parse(text)
        } else {
            generatedAt = nil
        }
    }
}

// MARK: - 日期字符串解析（兼容桌面端 ISO 带毫秒 / 不带毫秒）

enum ScheduleJSONDate {
    private static let formatters: [ISO8601DateFormatter] = {
        let withMillis = ISO8601DateFormatter()
        withMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withMillis, plain]
    }()

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

enum ScheduleNormalizer {
    /// 插件 normalizeItems 的移植：先清洗（cleanItem）再排序、去重叠、补空档，
    /// 保证 00:00–24:00 全覆盖。空档按官方规则补「睡觉 / 在家休息」；
    /// 最后一段不足则补到 24:00；上限 40 条。
    static func normalize(_ list: [ScheduleItem]) -> [ScheduleItem] {
        var items = list.compactMap { $0.cleaned() }.filter { $0.endMinute > $0.startMinute }
        items.sort { $0.startMinute == $1.startMinute ? $0.endMinute < $1.endMinute
                                                   : $0.startMinute < $1.startMinute }

        var out: [ScheduleItem] = []
        for var item in items {
            if let prev = out.last {
                if item.endMinute <= prev.endMinute { continue }          // 完全被上一条覆盖
                if item.startMinute < prev.endMinute {                    // 交集：起点顺延到上一条结尾
                    item.start = ScheduleItem.clock(minutes: prev.endMinute)
                }
            }
            if item.endMinute > item.startMinute { out.append(item) }
        }
        // 中间空档补「在家休息」：注入的 findItem 需要全天连续覆盖，
        // 否则空档里查不到"此刻在做什么"（桌面端不补中段，这里比它更完整）
        var filled: [ScheduleItem] = []
        for (index, item) in out.enumerated() {
            filled.append(item)
            if index + 1 < out.count, out[index + 1].startMinute > item.endMinute {
                filled.append(restItem(from: item.endMinute, to: out[index + 1].startMinute))
            }
        }
        out = filled

        // 空日程兜底：整日在家
        if out.isEmpty {
            return [ScheduleItem(start: "00:00", end: "24:00",
                                 activity: "在家", location: "家", detail: nil)]
        }
        // 开头有空档 → 睡觉
        if out[0].startMinute > 0 {
            out.insert(sleepItem(from: 0, to: out[0].startMinute), at: 0)
        }
        // 结尾：先补"在家休息"到 23:00（1380），再补"睡觉"到 24:00（1440）——同官方规则
        if let last = out.last, last.endMinute < 1380 {
            out.append(restItem(from: last.endMinute, to: 1380))
        }
        if let last = out.last, last.endMinute < 1440 {
            out.append(sleepItem(from: last.endMinute, to: 1440))
        }
        return Array(out.prefix(40))
    }

    private static func sleepItem(from: Int, to: Int) -> ScheduleItem {
        ScheduleItem(start: ScheduleItem.clock(minutes: from),
                     end: ScheduleItem.clock(minutes: to),
                     activity: "睡觉", location: "家", detail: nil)
    }

    private static func restItem(from: Int, to: Int) -> ScheduleItem {
        ScheduleItem(start: ScheduleItem.clock(minutes: from),
                     end: ScheduleItem.clock(minutes: to),
                     activity: "在家休息", location: "家", detail: nil)
    }
}
