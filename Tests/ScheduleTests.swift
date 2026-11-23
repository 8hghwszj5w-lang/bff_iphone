import XCTest
@testable import FenShen

/// 每日日程模块测试：数据归一化 / 清洗 / 临时调整 / 注入文本（含穿搭与生图参数） /
/// 素材库联动 / 解码兼容 / 两个工具
@MainActor
final class ScheduleTests: XCTestCase {
    private var store: ScheduleStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-tests-\(UUID().uuidString)", isDirectory: true)
        store = ScheduleStore(directory: directory)
        store.injectEnabled = true          // 注入开关在 UserDefaults 里，用例间互相隔离
    }

    override func tearDownWithError() throws {
        store.injectEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 归一化（对应插件 normalizeItems / cleanItem）

    func testNormalizeFillsGapsAndCapsAt24() {
        let items = [
            ScheduleItem(start: "09:00", end: "11:00", activity: "写代码", location: "公司", detail: nil),
            ScheduleItem(start: "13:00", end: "14:00", activity: "吃午饭", location: nil, detail: nil),
        ]
        let normalized = ScheduleNormalizer.normalize(items)
        XCTAssertEqual(normalized.first?.start, "00:00", "开头空档应补睡觉")
        XCTAssertEqual(normalized.last?.end, "24:00", "结尾应补到 24:00")
        // 09:00–11:00 与 13:00 之间应有"在家休息"补档（中间空档也要填满）
        XCTAssertTrue(normalized.contains { $0.activity == "在家休息" && $0.start == "11:00" })
        // 头睡 + 写代码 + 补档 + 午饭 + 尾部休息 + 尾睡 = 6
        XCTAssertEqual(normalized.count, 6)
    }

    func testNormalizeRemovesOverlapsAndEmptyDayFallsBack() {
        let overlapped = [
            ScheduleItem(start: "09:00", end: "12:00", activity: "上班", location: nil, detail: nil),
            ScheduleItem(start: "10:00", end: "11:00", activity: "摸鱼", location: nil, detail: nil),
        ]
        let normalized = ScheduleNormalizer.normalize(overlapped)
        // 被覆盖的"摸鱼"移除；头尾补睡 + 尾部休息 → 4 条
        XCTAssertEqual(normalized.count, 4)
        XCTAssertEqual(normalized.first { $0.activity == "上班" }?.end, "12:00", "保留的主段应完整")

        let empty = ScheduleNormalizer.normalize([])
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty[0].activity, "在家", "空日程应兜底为整日在")
    }

    /// 桌面端 cleanItem：end 写 "00:00" 且 start > 0 时归一为 "24:00"
    func testNormalizeFixesEndZeroTo24() {
        let normalized = ScheduleNormalizer.normalize([
            ScheduleItem(start: "09:00", end: "00:00", activity: "上班", location: "公司"),
        ])
        XCTAssertEqual(normalized.first { $0.activity == "上班" }?.end, "24:00")
    }

    /// 桌面端 cleanItem 的文本清洗：活性 40 / 地点 30 / detail 240 / outfitNote 60 / props·with 最多 4 条
    func testNormalizeCleansAndTruncatesText() {
        let long = String(repeating: "好", count: 60)
        let normalized = ScheduleNormalizer.normalize([
            ScheduleItem(start: "09:00", end: "10:00", activity: long, location: long,
                         detail: long, outfit: long,
                         outfitNote: String(repeating: "衣", count: 70),
                         props: ["一", "二", "三", "四", "五"],
                         with: ["甲", "乙", "丙", "丁", "戊"]),
        ])
        let item = normalized.first { $0.start == "09:00" }
        XCTAssertEqual(item?.activity.count, 40)
        XCTAssertEqual(item?.location?.count, 30)
        XCTAssertEqual(item?.detail?.count, 60 + 180, "detail 上限 240（这里没有超）")
        XCTAssertEqual(item?.outfitNote?.count, 60)
        XCTAssertEqual(item?.props?.count, 4, "props 最多 4 条")
        XCTAssertEqual(item?.with?.count, 4, "with 最多 4 条")
    }

    // MARK: 日期标签（桌面端 time.js dateLabel：'11月22日 星期日'）

    func testDateLabelUsesChineseWeekdayWithoutDuplicateWeekdayWord() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-22T10:00:00+08:00"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let label = ScheduleStore.dateLabel(for: date, timeZone: zone)
        XCTAssertEqual(label, "11月22日 星期日")
        XCTAssertFalse(label.contains("星期周"), "不能出现「星期周日」这种叠词")
    }

    // MARK: 临时调整（截断 / 拆开 / 记录 changes）

    func testAdjustSplitsOverlappingMiddleSegment() {
        store.saveDay(DaySchedule(date: "2026-11-18", items: [
            ScheduleItem(start: "09:00", end: "12:00", activity: "写代码", location: "工位", detail: nil),
        ]))
        store.adjust(dateKey: "2026-11-18", start: "10:00", end: "11:00",
                     activity: "被约出去喝咖啡", note: "朋友约", location: "咖啡屋")

        let day = store.loadDay(dateKey: "2026-11-18")
        let named = day?.items.filter { $0.activity.contains("咖啡") }
        XCTAssertEqual(named?.count, 1, "新段应插入")
        XCTAssertEqual(named?.first?.start, "10:00")
        // 原来的"写代码"应被拆成两段（09:00–10:00 与 11:00–12:00）
        let coding = day?.items.filter { $0.activity == "写代码" }
        XCTAssertEqual(coding?.count, 2, "中间插入应把原段拆成两半")
        XCTAssertEqual(coding?.first?.end, "10:00")
        XCTAssertEqual(coding?.last?.start, "11:00")
        XCTAssertEqual(day?.changes?.last?.note, "朋友约", "改主意原因应记入 changes")
    }

    func testAdjustTruncatesTailOverlap() {
        store.saveDay(DaySchedule(date: "2026-11-18", items: [
            ScheduleItem(start: "09:00", end: "12:00", activity: "写代码", location: nil, detail: nil),
        ]))
        store.adjust(dateKey: "2026-11-18", start: "11:00", end: "12:30",
                     activity: "开会", note: "临时会议", location: nil)
        let day = store.loadDay(dateKey: "2026-11-18")
        XCTAssertTrue(day?.items.contains { $0.activity == "开会" && $0.end == "12:30" } ?? false)
        XCTAssertTrue(day?.items.contains { $0.activity == "写代码" && $0.end == "11:00" } ?? false,
                      "重叠部分应被截断")
    }

    /// 桌面端 index.js:88：没有这一天的日程就直接拒绝，不凭空造一天
    func testAdjustRefusesWhenNoScheduleExists() {
        let result = store.adjust(dateKey: "2099-01-01", start: "10:00", end: "11:00",
                                  activity: "出门", note: "测试")
        XCTAssertEqual(result, .noSchedule)
        XCTAssertNil(store.loadDay(dateKey: "2099-01-01"), "不应凭空造出一天的日程文件")
    }

    /// 桌面端 index.js:89-96：没写 outfit / outfit_note 时沿用那个时间点原本的穿着
    func testAdjustInheritsOutfitWhenNotSpecified() throws {
        store.saveDay(DaySchedule(date: "2026-11-18", items: [
            ScheduleItem(start: "09:00", end: "12:00", activity: "写代码", location: "工位",
                         outfit: "毛衣", outfitNote: "蓝色"),
        ]))
        let result = store.adjust(dateKey: "2026-11-18", start: "10:00", end: "11:00",
                                  activity: "去楼下买咖啡", note: "想喝了")
        guard case .ok(let day) = result else { return XCTFail("应调整成功：\(result)") }
        let item = try XCTUnwrap(day.items.first { $0.activity == "去楼下买咖啡" })
        XCTAssertEqual(item.outfit, "毛衣", "没写 outfit 应沿用原时段的穿着")
        XCTAssertEqual(item.outfitNote, "蓝色")
    }

    /// 素材库可用时 adjust 校验名字（fill=false）：别名对正名、库里没有的转备注
    func testAdjustValidatesNamesAgainstWardrobe() throws {
        store.wardrobeProvider = { Self.wardrobe() }
        store.saveDay(DaySchedule(date: "2026-11-18", items: [
            ScheduleItem(start: "00:00", end: "09:00", activity: "睡觉", location: "家"),
            ScheduleItem(start: "09:00", end: "24:00", activity: "上班", location: "公司"),
        ]))
        let result = store.adjust(dateKey: "2026-11-18", start: "10:00", end: "11:00",
                                  activity: "去楼下买咖啡", note: "想喝了",
                                  outfit: "针织服", outfitNote: "外面加了件围裙")
        guard case .ok(let day) = result else { return XCTFail("应调整成功：\(result)") }
        let item = try XCTUnwrap(day.items.first { $0.activity == "去楼下买咖啡" })
        XCTAssertEqual(item.outfit, "居家针织服", "别名应换成库里的正名")
        XCTAssertEqual(item.outfitNote, "外面加了件围裙")

        let unknown = store.adjust(dateKey: "2026-11-18", start: "11:00", end: "12:00",
                                   activity: "换衣服", note: "试试",
                                   outfit: "米色风衣")
        guard case .ok(let day2) = unknown else { return XCTFail("应调整成功：\(unknown)") }
        let item2 = try XCTUnwrap(day2.items.first { $0.activity == "换衣服" })
        XCTAssertNil(item2.outfit, "库里没有的名字不应留在 outfit")
        XCTAssertEqual(item2.outfitNote, "米色风衣", "库里没有的衣服应转成备注")
    }

    // MARK: 注入文本（system 消息里的"生活背景"）

    func testInjectionTextContainsCoreBlocks() {
        let now = Date()
        let key = ScheduleStore.dateKey(for: now)
        store.saveDay(DaySchedule(date: key, dayTypeName: "上班日", title: "忙碌的周三",
                                  mood: "平稳", items: [
            ScheduleItem(start: "00:00", end: "08:00", activity: "睡觉", location: "家", detail: nil),
            ScheduleItem(start: "08:00", end: "09:00", activity: "通勤", location: "地铁", detail: nil),
            ScheduleItem(start: "09:00", end: "12:00", activity: "写代码干活", location: "工位",
                         detail: "上午状态不错"),
            ScheduleItem(start: "12:00", end: "24:00", activity: "下班后自由时间", location: nil, detail: nil),
        ]))
        let text = store.injectionText(now: dateAt(hour: 10, minute: 10))
        XCTAssertTrue(text.contains("# 小深此刻的生活"), "应有标题行")
        XCTAssertTrue(text.contains("她正在：写代码干活（工位），从 09:00 到 12:00 左右——上午状态不错"))
        XCTAssertTrue(text.contains("她今天早些时候：通勤"), "早些时候应列出（排除睡觉）")
        XCTAssertTrue(text.contains("【怎么把这些带进聊天】"), "应包含说话方式")
        XCTAssertTrue(text.contains("schedule_adjust"), "应包含工具用法提示")
        XCTAssertTrue(text.contains("让你做正事"), "应有正事优先兜底")
        XCTAssertFalse(text.contains("{角色名}"), "占位符应被替换")
        XCTAssertFalse(text.contains("{称呼}"), "占位符应被替换")
    }

    func testInjectionTextWithoutScheduleKeepsFallback() {
        let text = store.injectionText(now: dateAt(hour: 10, minute: 0))
        XCTAssertTrue(text.contains("她今天过得怎样还没想好"), "无日程时应有兜底句")
        XCTAssertTrue(text.contains("【怎么把这些带进聊天】"), "无日程时也应带上说话方式（桌面端 inject.js:51）")
    }

    func testInjectionTextMentionsSleepTone() {
        let key = ScheduleStore.dateKey(for: dateAt(hour: 23, minute: 0))
        store.saveDay(DaySchedule(date: key, items: [
            ScheduleItem(start: "22:00", end: "24:00", activity: "睡觉", location: "家", detail: nil),
        ]))
        let text = store.injectionText(now: dateAt(hour: 23, minute: 0))
        XCTAssertTrue(text.contains("睡着了"), "睡觉时段应提示困意语气")
    }

    /// 注入全局开关（对应桌面端 cfg.inject.enabled）：关掉时返回空串，日程本身不受影响
    func testInjectionGlobalSwitch() {
        let key = ScheduleStore.dateKey(for: Date())
        store.saveDay(DaySchedule(date: key, items: [
            ScheduleItem(start: "00:00", end: "24:00", activity: "在家", location: "家"),
        ]))
        store.injectEnabled = false
        XCTAssertEqual(store.injectionText(now: dateAt(hour: 10, minute: 0)), "",
                       "关掉注入后不应拼任何文本")
        store.injectEnabled = true
        XCTAssertFalse(store.injectionText(now: dateAt(hour: 10, minute: 0)).isEmpty)
    }

    /// 穿搭 / 物品 / 人物 / 换装时间线 / 生图参数行（桌面端 inject.js:59-84）
    func testInjectionTextIncludesOutfitPropsCompanyAndImageParams() {
        store.wardrobeProvider = { Self.wardrobe() }
        let key = ScheduleStore.dateKey(for: dateAt(hour: 10, minute: 10))
        store.saveDay(DaySchedule(date: key, dayTypeName: "休息日", title: "在家收拾", items: [
            ScheduleItem(start: "00:00", end: "08:00", activity: "睡觉", location: "家", outfit: "睡衣"),
            ScheduleItem(start: "08:00", end: "12:00", activity: "在家收拾", location: "家",
                         detail: "把衣柜整理了一遍", outfit: "居家针织服", outfitNote: "外面加了件开衫",
                         scene: "客厅", situation: "在家休息", props: ["马克杯", "抱枕"], with: ["阿哲"]),
            ScheduleItem(start: "12:00", end: "24:00", activity: "自己的时间", location: "家"),
        ]))
        let text = store.injectionText(now: dateAt(hour: 10, minute: 10))
        XCTAssertTrue(text.contains("身上穿着「居家针织服」（外面加了件开衫）"), text)
        XCTAssertTrue(text.contains("手边有马克杯、抱枕"), text)
        XCTAssertTrue(text.contains("和阿哲在一起"), text)
        XCTAssertTrue(text.contains("她今天换过的衣服：「睡衣」 → 08:00 起「居家针织服」（外面加了件开衫）"), text)
        XCTAssertTrue(text.contains("characters 填「梁小鱼」"), text)
        XCTAssertTrue(text.contains("outfits 填「居家针织服」"), text)
        XCTAssertTrue(text.contains("prompt 里写上「外面加了件开衫」"), text)
        XCTAssertTrue(text.contains("scene 填「客厅」"), text)
        XCTAssertTrue(text.contains("situation 填「在家休息」"), text)
        XCTAssertTrue(text.contains("props 可以加「马克杯、抱枕」"), text)
    }

    /// 傍晚后注入明天的安排，含「想穿「X」」（桌面端 inject.js:71-77）
    func testInjectionTextTomorrowIncludesOutfitToWear() {
        let now = dateAt(hour: 19, minute: 10)
        let todayKey = ScheduleStore.dateKey(for: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let tomorrowKey = ScheduleStore.dateKey(for: tomorrow)
        store.saveDay(DaySchedule(date: todayKey, items: [
            ScheduleItem(start: "00:00", end: "24:00", activity: "在家", location: "家"),
        ]))
        store.saveDay(DaySchedule(date: tomorrowKey, dayTypeName: "外出日", title: "去逛街", items: [
            ScheduleItem(start: "00:00", end: "09:00", activity: "睡觉", location: "家", outfit: "睡衣"),
            ScheduleItem(start: "09:00", end: "24:00", activity: "逛街", location: "市中心", outfit: "风衣"),
        ]))
        let text = store.injectionText(now: now)
        XCTAssertTrue(text.contains("想穿「风衣」"), text)
        XCTAssertTrue(text.contains("去逛街"), text)
    }

    /// 没接生图工作室（wardrobeProvider = nil）时降级：只按文字，不出现生图参数行
    func testInjectionWithoutWardrobeDegradesToTextOnly() {
        let key = ScheduleStore.dateKey(for: dateAt(hour: 10, minute: 10))
        store.saveDay(DaySchedule(date: key, items: [
            ScheduleItem(start: "00:00", end: "24:00", activity: "在家看书", location: "家", outfit: "睡衣"),
        ]))
        let text = store.injectionText(now: dateAt(hour: 10, minute: 10))
        XCTAssertTrue(text.contains("身上穿着「睡衣」"), "穿搭来自日程本身，不依赖素材库")
        XCTAssertFalse(text.contains("image_generate）画她此刻的样子时："), "没素材库时不应给生图参数")
    }

    // MARK: schedule_view 文本

    func testDayTextListsItemsAndChanges() {
        guard let key = ScheduleStore.dayKey(for: "today") else {
            return XCTFail("today 应能解析出日期 key")
        }
        store.saveDay(DaySchedule(date: key, dayTypeName: "上班日", title: "忙碌", mood: "平稳", items: [
            ScheduleItem(start: "09:00", end: "12:00", activity: "上班", location: "公司", detail: nil,
                         outfit: "西装", situation: "工作学习", props: ["保温杯"], with: ["阿哲"]),
        ], changes: [ScheduleChange(at: Date(), note: "朋友约")]))
        let text = store.dayText(for: key)
        XCTAssertTrue(text.contains(ScheduleStore.dateLabel(forDayKey: key)), "标题应是日期标签，不是 yyyy-MM-dd")
        XCTAssertTrue(text.contains("09:00–12:00 上班（公司）"))
        XCTAssertTrue(text.contains("[情境：工作学习；穿着：「西装」；物品：保温杯；和：阿哲]"), text)
        XCTAssertTrue(text.contains("临时改过 1 次主意：朋友约"))
        XCTAssertTrue(text.contains("别提「日程」"), "末尾应带措辞提醒")
    }

    // MARK: 素材库联动（dress.js linkItems / wardrobePrompt）

    func testLinkItemsResolvesAliasesAndFillsOutfitBySituation() {
        let wardrobe = Self.wardrobe()
        let items = [
            ScheduleItem(start: "09:00", end: "12:00", activity: "上班", location: "公司"),
            ScheduleItem(start: "12:00", end: "13:00", activity: "吃午饭", location: "公司附近"),
        ]
        let linked = ScheduleWardrobeLink.linkItems(items, wardrobe: wardrobe, fill: true)
        // 「上班」→ 工作学习情境，她的情境穿搭是 白衬衫/西装（优先她的情境穿搭）
        XCTAssertEqual(linked.first?.outfit, "白色衬衫", linked.first?.outfit ?? "")
        XCTAssertEqual(linked.first?.scene, "公司", "地点文字应认出来是场景库里的公司")
        // 第二段同一情境 → 延续上一段穿着
        XCTAssertEqual(linked.last?.outfit, linked.first?.outfit)
    }

    func testLinkItemsTurnsUnknownOutfitIntoNoteAndFillsFromSceneOrDefault() {
        let wardrobe = Self.wardrobe()
        let items = [
            ScheduleItem(start: "09:00", end: "12:00", activity: "在咖啡屋坐坐", location: "江畔暖灯咖啡屋"),
            ScheduleItem(start: "12:00", end: "13:00", activity: "在家躺着", location: "家", outfit: "不存在的外套"),
        ]
        let linked = ScheduleWardrobeLink.linkItems(items, wardrobe: wardrobe, fill: true)
        XCTAssertEqual(linked.first?.scene, "江畔暖灯咖啡屋", "地点文字应认出场景")
        XCTAssertEqual(linked.last?.outfit, nil, "库里没有的衣服不留 outfit")
        XCTAssertEqual(linked.last?.outfitNote, "不存在的外套", "库里没有的衣服应转成备注")
    }

    func testLinkItemsHandlesPropsAndPeopleLimits() {
        let wardrobe = Self.wardrobe()
        let item = ScheduleItem(start: "09:00", end: "10:00", activity: "看剧", location: "家",
                                props: ["马克杯", "马克杯", "抱枕", "小说", "耳机"],
                                with: ["阿哲", "阿哲", "林小雨"])
        let linked = ScheduleWardrobeLink.linkItems([item], wardrobe: wardrobe, fill: true)
        XCTAssertEqual(linked[0].props, ["马克杯", "抱枕", "小说"], "props 去重、最多 3 个")
        XCTAssertEqual(linked[0].with, ["阿哲", "林小雨"], "with 去重、最多 4 个")
    }

    func testLinkItemsWithoutWardrobeReturnsInputUnchanged() {
        let items = [ScheduleItem(start: "09:00", end: "10:00", activity: "看剧", outfit: "睡衣")]
        XCTAssertEqual(ScheduleWardrobeLink.linkItems(items, wardrobe: nil, fill: true), items)
        let empty = ScheduleWardrobe()
        XCTAssertEqual(ScheduleWardrobeLink.linkItems(items, wardrobe: empty, fill: true), items)
    }

    func testWardrobePromptListsLibraryAndRules() {
        let parts = ScheduleWardrobeLink.wardrobePrompt(Self.wardrobe())
        XCTAssertTrue(parts.sections.contains("【她的衣柜】"), parts.sections)
        XCTAssertTrue(parts.sections.contains("【她平时的穿搭习惯】"), parts.sections)
        XCTAssertTrue(parts.sections.contains("【常去的地方】"), parts.sections)
        XCTAssertTrue(parts.sections.contains("【她的物品】"), parts.sections)
        XCTAssertTrue(parts.sections.contains("【认识的人】"), parts.sections)
        XCTAssertTrue(parts.rules.contains { $0.hasPrefix("- outfit：") })
        XCTAssertTrue(parts.rules.contains { $0.hasPrefix("- scene：") })
        XCTAssertEqual(parts.example["outfit"] as? String, "居家针织服", "衣柜里有睡衣类条目时示例用它的名字")
        XCTAssertEqual(parts.example["scene"] as? String, "客厅")
    }

    /// 解码要容忍桌面端 JSON：dayType 对象、error 字段、outfit_note、ISO 日期、changes 的 at
    func testDayScheduleDecodesDesktopJSON() throws {
        let json = """
        {
          "date": "2026-11-22",
          "dayType": { "id": "workday", "name": "上班日" },
          "title": "忙碌的一天", "mood": "平稳", "source": "llm",
          "error": "模型当时超时", "generatedAt": "2026-11-21T14:00:00.000Z",
          "items": [
            {"start": "00:00", "end": "07:00", "activity": "睡觉", "location": "家",
             "outfit": "睡衣", "outfit_note": "蓝色的", "scene": "卧室", "situation": "睡前",
             "props": "马克杯", "with": ["阿哲"]}
          ],
          "changes": [{ "at": "2026-11-21T15:00:00Z", "note": "临时改过" }]
        }
        """
        let day = try JSONDecoder().decode(DaySchedule.self, from: Data(json.utf8))
        XCTAssertEqual(day.dayTypeName, "上班日")
        XCTAssertEqual(day.generationError, "模型当时超时")
        XCTAssertNotNil(day.generatedAt, "桌面端的 ISO 时间字符串也要能解")
        XCTAssertEqual(day.items.first?.outfitNote, "蓝色的", "outfit_note 别名应映射到 outfitNote")
        XCTAssertEqual(day.items.first?.props, ["马克杯"], "props 字符串应转成数组")
        XCTAssertEqual(day.items.first?.with, ["阿哲"])
        XCTAssertEqual(day.changes?.first?.note, "临时改过")
        XCTAssertNotNil(day.changes?.first?.at)
    }

    // MARK: schedule_adjust / schedule_view 工具

    func testScheduleToolsRoundTrip() async {
        // 无日程时 schedule_adjust 直接拒绝（桌面端 index.js:88）
        let adjust = ScheduleAdjustTool(store: store)
        let view = ScheduleViewTool(store: store)
        let refused = await adjust.run(argumentsJSON: """
        {"day": "today", "start": "14:00", "end": "15:00", "activity": "去健身房", "reason": "晚上要聚餐"}
        """)
        XCTAssertTrue(refused.contains("这一天还没有日程"), refused)
        XCTAssertNil(store.loadDay(dateKey: ScheduleStore.dayKey(for: "today")!))

        // 先有一天日程，再调整
        store.saveDay(DaySchedule(date: ScheduleStore.dayKey(for: "today")!, items: [
            ScheduleItem(start: "00:00", end: "24:00", activity: "待着", location: "家"),
        ]))
        let adjustJSON = """
        {"day": "today", "start": "14:00", "end": "15:00",
         "activity": "去健身房", "reason": "晚上要聚餐", "location": "楼下健身房"}
        """
        let adjustResult = await adjust.run(argumentsJSON: adjustJSON)
        XCTAssertTrue(adjustResult.contains("已记下"), "应返回确认话术：\(adjustResult)")
        XCTAssertTrue(adjustResult.contains("14:00–15:00 改成「去健身房」：晚上要聚餐"), adjustResult)

        let viewResult = await view.run(argumentsJSON: "{\"day\": \"today\"}")
        XCTAssertTrue(viewResult.contains("14:00–15:00 去健身房（楼下健身房）"), "schedule_view 应看到调整结果：\(viewResult)")

        let bad = await adjust.run(argumentsJSON: "{\"start\": \"没有时间\", \"end\": \"15:00\", \"activity\": \"x\", \"reason\": \"y\"}")
        XCTAssertTrue(bad.contains("error"), "非法时间应返回错误")
    }

    func testScheduleToolRejectsInvalidUpdatesWithoutChangingEitherDay() async throws {
        let tool = ScheduleAdjustTool(store: store)
        for name in ["today", "yesterday"] {
            let key = try XCTUnwrap(ScheduleStore.dayKey(for: name))
            let original = DaySchedule(date: key, items: [
                ScheduleItem(start: "00:00", end: "24:00", activity: "原安排")
            ])
            store.saveDay(original)
            let ranges = name == "today" ? [("xx:00", "12:00"), ("10::00", "12:00"), ("10:00", "24:01"), ("12:00", "11:00")] : [("10:00", "12:00")]
            for (start, end) in ranges {
                let reply = await tool.run(argumentsJSON: """
                {"day":"\(name)","start":"\(start)","end":"\(end)","activity":"新安排","reason":"测试"}
                """)
                XCTAssertTrue(reply.contains("error"), reply)
                XCTAssertEqual(store.loadDay(dateKey: key), original)
            }
        }
    }

    func testScheduleToolPreservesDetailsWhenSplitting() async throws {
        let key = try XCTUnwrap(ScheduleStore.dayKey(for: "today"))
        let original = ScheduleItem(start: "00:00", end: "24:00", activity: "读书", location: "家", detail: "读小说", outfit: "毛衣", outfitNote: "蓝色")
        store.saveDay(DaySchedule(date: key, items: [original]))
        _ = await ScheduleAdjustTool(store: store).run(argumentsJSON: """
        {"start":"10:00","end":"12:00","activity":"出门","reason":"约好了","detail":"去见朋友"}
        """)
        var before = original, after = original
        before.end = "10:00"
        after.start = "12:00"
        // 桌面端：没写 outfit / outfit_note 时沿用那个时间点原本的穿着
        let inserted = ScheduleItem(start: "10:00", end: "12:00", activity: "出门", detail: "去见朋友",
                                    outfit: "毛衣", outfitNote: "蓝色")
        let items = try XCTUnwrap(store.loadDay(dateKey: key)?.items)
        XCTAssertEqual(items, [before, inserted, after])
    }

    func testInjectionUsesRequestedZoneForActivityAndTomorrowAcrossMidnight() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T10:45:00Z"))
        let west = try XCTUnwrap(TimeZone(secondsFromGMT: -12 * 3600)) // 12/31 22:45
        let east = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 3600))   // 1/1 19:45
        for key in ["2025-12-31", "2026-01-01", "2026-01-02"] {
            store.saveDay(DaySchedule(date: key, title: key, items: [
                ScheduleItem(start: "18:00", end: "21:00", activity: "散步"),
                ScheduleItem(start: "21:00", end: "24:00", activity: "读书")
            ]))
        }
        for (zone, time, activity, tomorrow) in [(west, "22:30", "读书", "2026-01-01"), (east, "19:30", "散步", "2026-01-02"), (west, "22:30", "读书", "2026-01-01")] {
            let text = store.injectionText(now: now, timeZone: zone)
            XCTAssertTrue(text.contains("约 \(time)"))
            XCTAssertTrue(text.contains("她正在：\(activity)"))
            XCTAssertTrue(text.contains("她打算：\(tomorrow)"))
        }
    }

    // MARK: 素材库测试数据

    /// 一份覆盖衣柜 / 场景 / 道具 / 人物 / 情境的快照：
    /// · 她 = 梁小鱼，平时穿「居家针织服」，工作学习时穿「白色衬衫」
    /// · 衣柜别名：针织服 → 居家针织服；睡衣
    /// · 场景：客厅（卧室/房间）、公司、江畔暖灯咖啡屋
    /// · 道具：马克杯 / 抱枕 / 小说 / 耳机；人物：阿哲 / 林小雨
    static func wardrobe() -> ScheduleWardrobe {
        ScheduleWardrobe(
            herName: "梁小鱼",
            herDefaultOutfit: "居家针织服",
            herSituationOutfits: ["工作学习": "白色衬衫"],
            outfits: [
                ScheduleWardrobeItem(name: "居家针织服", aliases: ["针织服"], tags: ["睡衣", "居家"]),
                ScheduleWardrobeItem(name: "白色衬衫", tags: ["工作"]),
                ScheduleWardrobeItem(name: "风衣"),
            ],
            scenes: [
                ScheduleWardrobeItem(name: "客厅", aliases: ["卧室", "房间"], tags: ["在家"],
                                     defaultOutfit: "居家针织服"),
                ScheduleWardrobeItem(name: "公司", defaultOutfit: "白色衬衫"),
                ScheduleWardrobeItem(name: "江畔暖灯咖啡屋", tags: ["咖啡"]),
            ],
            props: [
                ScheduleWardrobeItem(name: "马克杯"),
                ScheduleWardrobeItem(name: "抱枕"),
                ScheduleWardrobeItem(name: "小说"),
                ScheduleWardrobeItem(name: "耳机"),
            ],
            people: [ScheduleWardrobeItem(name: "阿哲"), ScheduleWardrobeItem(name: "林小雨")],
            situations: [
                ScheduleWardrobeSituation(name: "在家休息", aliases: ["宅家"], scene: "客厅", outfit: "居家针织服"),
                ScheduleWardrobeSituation(name: "工作学习", aliases: ["上班"], scene: "公司", outfit: "白色衬衫"),
                ScheduleWardrobeSituation(name: "外出", scene: "", outfit: "风衣"),
            ])
    }

    // MARK: 工具

    private func dateAt(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
}
