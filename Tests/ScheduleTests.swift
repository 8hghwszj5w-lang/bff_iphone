import XCTest
@testable import FenShen

/// 每日日程模块测试：数据归一化 / 临时调整的截断拆分 / 注入文本 / 两个工具
@MainActor
final class ScheduleTests: XCTestCase {
    private var store: ScheduleStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-tests-\(UUID().uuidString)", isDirectory: true)
        store = ScheduleStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 归一化（对应插件 normalizeItems）

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
    }

    func testInjectionTextWithoutScheduleKeepsFallback() {
        let text = store.injectionText(now: dateAt(hour: 10, minute: 0))
        XCTAssertTrue(text.contains("她今天过得怎样还没想好"), "无日程时应有兜底句")
    }

    func testInjectionTextMentionsSleepTone() {
        let key = ScheduleStore.dateKey(for: dateAt(hour: 23, minute: 0))
        store.saveDay(DaySchedule(date: key, items: [
            ScheduleItem(start: "22:00", end: "24:00", activity: "睡觉", location: "家", detail: nil),
        ]))
        let text = store.injectionText(now: dateAt(hour: 23, minute: 0))
        XCTAssertTrue(text.contains("睡着了"), "睡觉时段应提示困意语气")
    }

    // MARK: schedule_view 文本

    func testDayTextListsItemsAndChanges() {
        guard let key = ScheduleStore.dayKey(for: "today") else {
            return XCTFail("today 应能解析出日期 key")
        }
        store.saveDay(DaySchedule(date: key, items: [
            ScheduleItem(start: "09:00", end: "12:00", activity: "上班", location: "公司", detail: nil),
        ], changes: [ScheduleChange(at: Date(), note: "朋友约")]))
        let text = store.dayText(for: key)
        XCTAssertTrue(text.contains("09:00–12:00 上班（公司）"))
        XCTAssertTrue(text.contains("临时改过 1 次主意：朋友约"))
        XCTAssertTrue(text.contains("别提「日程」"), "末尾应带措辞提醒")
    }

    // MARK: schedule_adjust / schedule_view 工具

    func testScheduleToolsRoundTrip() async {
        let adjust = ScheduleAdjustTool(store: store)
        let view = ScheduleViewTool(store: store)
        let adjustJSON = """
        {"day": "today", "start": "14:00", "end": "15:00",
         "activity": "去健身房", "reason": "晚上要聚餐", "location": "楼下健身房"}
        """
        let adjustResult = await adjust.run(argumentsJSON: adjustJSON)
        XCTAssertTrue(adjustResult.contains("记下了"), "应返回确认话术：\(adjustResult)")
        XCTAssertTrue(adjustResult.contains("14:00–15:00 去健身房"))

        let viewResult = await view.run(argumentsJSON: "{\"day\": \"today\"}")
        XCTAssertTrue(viewResult.contains("14:00–15:00 去健身房（楼下健身房）"), "schedule_view 应看到调整结果：\(viewResult)")

        let bad = await adjust.run(argumentsJSON: "{\"start\": \"没有时间\", \"end\": \"15:00\", \"activity\": \"x\", \"reason\": \"y\"}")
        XCTAssertTrue(bad.contains("error"), "非法时间应返回错误")
    }

    // MARK: 工具

    private func dateAt(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
}
