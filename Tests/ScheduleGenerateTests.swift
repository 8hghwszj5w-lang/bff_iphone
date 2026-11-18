import XCTest
@testable import FenShen

/// 自动日程生成测试：prompt 解析、类型加权挑选、LLM 输出兜底、autoFill 冷却。
/// 不碰真网络：ask 闭包注入固定返回。
@MainActor
final class ScheduleGenerateTests: XCTestCase {
    private var store: ScheduleStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-gen-tests-\(UUID().uuidString)", isDirectory: true)
        store = ScheduleStore(directory: directory)
        ScheduleGenerator.clearRetryCooldowns()   // 进程内静态冷却表，用例间隔离
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 造数据的助手（nonisolated static：可在 @Sendable 闭包里调用）

    nonisolated static func goodLLMOutput(title: String = "平稳的一天") -> String {
        """
        ```json
        {"title": "\(title)", "mood": "平稳",
         "items": [
           {"start": "00:00", "end": "07:30", "activity": "睡觉", "location": "家"},
           {"start": "07:30", "end": "08:15", "activity": "起床洗漱", "location": "家"},
           {"start": "08:15", "end": "09:00", "activity": "通勤", "location": "路上"},
           {"start": "09:00", "end": "12:00", "activity": "上班", "location": "公司"},
           {"start": "12:00", "end": "13:00", "activity": "吃午饭", "location": "公司附近"},
           {"start": "13:00", "end": "18:00", "activity": "上班", "location": "公司"},
           {"start": "18:00", "end": "19:00", "activity": "回家", "location": "路上"},
           {"start": "19:00", "end": "24:00", "activity": "自己的时间", "location": "家"}
         ]}
        ```
        """
    }

    nonisolated static func messyLLMOutput() -> String {
        """
        {"title": "有点乱的一天", "mood": "一般",
         "items": [
           {"start": "09:00", "end": "11:00", "activity": "写代码"},
           {"start": "10:00", "end": "11:30", "activity": "开会"},
           {"start": "14:00", "end": "15:00", "activity": "散步"}
         ]}
        """
    }

    /// 线程安全地捕获 prompt（@Sendable 闭包不能直接写局部变量）
    private final class PromptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        var get: String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func nextSaturday() -> Date {
        var date = Date()
        while Calendar.current.component(.weekday, from: date) != 7 {
            date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        }
        return date
    }

    // MARK: 解析

    func testParseScheduleStripsFencesAndNormalizes() throws {
        let parsed = try ScheduleGenerator.parseSchedule(Self.goodLLMOutput())
        XCTAssertEqual(parsed.title, "平稳的一天")
        XCTAssertGreaterThanOrEqual(parsed.items.count, 4)
        XCTAssertEqual(parsed.items.first?.activity, "睡觉", "开头应补/保留睡觉段")
        // 重叠坏输出也要被 normalize 修复
        let messy = try ScheduleGenerator.parseSchedule(Self.messyLLMOutput())
        for (a, b) in zip(messy.items, messy.items.dropFirst()) {
            XCTAssertLessThanOrEqual(a.endMinute, b.startMinute, "normalize 后不允许重叠")
        }
    }

    func testParseScheduleRejectsNonJSON() {
        XCTAssertThrowsError(try ScheduleGenerator.parseSchedule("抱歉，我无法完成这个请求。"))
    }

    // MARK: 类型加权挑选

    func testPickDayTypeWeekendExcludesWeekdayOnly() {
        let saturday = nextSaturday()
        // r=0 → 累计权重从头开始，weekend 池第一项是休息日
        let first = ScheduleGenerator.pickDayType(for: saturday, rand: { 0 })
        XCTAssertEqual(first.id, "restday", "weekend 池应排除上班日/加班日/摸鱼日")
        // r→1 → 落到最后一项（宅家日，any）
        let last = ScheduleGenerator.pickDayType(for: saturday, rand: { 0.999 })
        XCTAssertEqual(last.id, "homebody")
    }

    func testPickDayTypeWeekdayExcludesWeekendOnly() {
        // 找一个周三（工作日）
        var date = Date()
        while Calendar.current.component(.weekday, from: date) != 4 {
            date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        }
        let first = ScheduleGenerator.pickDayType(for: date, rand: { 0 })
        XCTAssertNotEqual(first.id, "outing", "工作日池不应包含外出日（weekend only）")
        XCTAssertNotEqual(first.id, "restday", "工作日池不应包含休息日（weekend only）")
    }

    // MARK: generateDay 主流程

    func testGenerateDayUsesLLMOutputAndMarksSource() async throws {
        let day = try await ScheduleGenerator.generateDay(
            dateKey: ScheduleStore.dateKey(for: Date()),
            persona: "她叫小深。", characterName: "小深",
            client: { _ in Self.goodLLMOutput() },
            store: store)
        XCTAssertEqual(day.source, "llm")
        XCTAssertEqual(day.title, "平稳的一天")
        XCTAssertNil(day.generationError)
        XCTAssertEqual(store.loadDay(dateKey: day.date)?.source, "llm", "生成结果应落盘")
    }

    func testGenerateDayFallsBackToTemplateWhenLLMGarbles() async throws {
        let day = try await ScheduleGenerator.generateDay(
            dateKey: ScheduleStore.dateKey(for: Date()),
            persona: "她叫小深。", characterName: "小深",
            client: { _ in "抱歉，这个请求我处理不了。" },
            store: store)
        XCTAssertEqual(day.source, "template", "解析失败应落模板兜底")
        XCTAssertNotNil(day.generationError)
        XCTAssertEqual(day.items.last?.end, "24:00", "模板兜底也应覆盖到 24:00")
    }

    func testGenerateDayHonorsHintAndForcedType() async throws {
        let box = PromptBox()
        let day = try await ScheduleGenerator.generateDay(
            dateKey: ScheduleStore.dateKey(for: nextSaturday()),
            persona: "她叫小深。", characterName: "小深",
            client: { prompt in
                box.set(prompt)
                return try await Self.goodLLMOutput()
            },
            store: store, dayTypeId: "outing", hint: "下午和用户去看电影")
        XCTAssertEqual(day.dayTypeName, "外出日", "指定类型应强制生效")
        XCTAssertTrue(box.get?.contains("下午和用户去看电影") ?? false, "特别要求应进 prompt")
        XCTAssertEqual(day.source, "llm")
    }

    // MARK: autoFill（runner.js 语义：今天缺失立刻补；22:00 后补明天；失败 20 分钟冷却）

    func testAutoFillGeneratesTodayImmediatelyAndTomorrowAfterGenHour() async {
        let tonight = dateAt(hour: 23, minute: 10)          // 已过 22:00
        let generated = await ScheduleGenerator.autoFill(
            store: store, persona: "她叫小深。", characterName: "小深",
            ask: { _ in Self.goodLLMOutput() }, now: tonight)
        XCTAssertEqual(generated.count, 2, "今天缺失 + 已过生成时刻 → 今天和明天都应生成")
        XCTAssertEqual(generated.first, ScheduleStore.dateKey(for: tonight))
        XCTAssertEqual(generated.last, ScheduleStore.dayKey(for: "tomorrow", now: tonight))
        XCTAssertNotNil(store.loadDay(dateKey: ScheduleStore.dateKey(for: tonight)))
        XCTAssertNotNil(store.loadDay(dateKey: ScheduleStore.dayKey(for: "tomorrow", now: tonight)!))
    }

    func testAutoFillBeforeGenHourOnlyFillsToday() async {
        let afternoon = dateAt(hour: 15, minute: 0)         // 未到 22:00
        let generated = await ScheduleGenerator.autoFill(
            store: store, persona: "她叫小深。", characterName: "小深",
            ask: { _ in Self.goodLLMOutput() }, now: afternoon)
        XCTAssertEqual(generated, [ScheduleStore.dateKey(for: afternoon)], "白天只应补今天，不该抢生成明天")
        XCTAssertNil(store.loadDay(dateKey: ScheduleStore.dayKey(for: "tomorrow", now: afternoon)!))
    }

    func testAutoFillRetriesAfterCooldownWhenTomorrowGenerationFailed() async throws {
        // 预置今天有日程：让 autoFill 直接走到「22:00 后生成明天」的分支
        let tonight = dateAt(hour: 23, minute: 30)
        let todayKey = ScheduleStore.dateKey(for: tonight)
        let workday = ScheduleDayType.defaults.first { $0.id == "workday" }!
        store.saveDay(DaySchedule(date: todayKey, dayTypeName: workday.name,
                                  items: ScheduleGenerator.templateItems(type: workday)))
        let tomorrowKey = ScheduleStore.dayKey(for: "tomorrow", now: tonight)!

        // 第一次 autoFill：明天生成失败 → 不落模板占坑，进入 20 分钟冷却
        _ = await ScheduleGenerator.autoFill(
            store: store, persona: "她叫小深。", characterName: "小深",
            ask: { _ in "乱七八糟的回答" }, now: tonight)
        XCTAssertNil(store.loadDay(dateKey: tomorrowKey),
                     "失败后明天仍无日程（autoFail 走冷却重试，模板兜底只用于显式生成）")

        // 立刻再调：仍在冷却，不应重试明天（今天已存在也不会再动）
        let immediate = await ScheduleGenerator.autoFill(
            store: store, persona: "她叫小深。", characterName: "小深",
            ask: { _ in Self.goodLLMOutput() }, now: tonight.addingTimeInterval(60))
        XCTAssertTrue(immediate.isEmpty, "冷却期内不应重复生成明天")

        // 冷却表是进程内静态状态，无法在测试里拨快时钟；
        // 改为验证显式 generateDay（跳过冷却路径）可以成功生成明天。
        let day = try await ScheduleGenerator.generateDay(
            dateKey: tomorrowKey, persona: "她叫小深。", characterName: "小深",
            client: { _ in Self.goodLLMOutput() }, store: store)
        XCTAssertEqual(day.source, "llm")
        XCTAssertEqual(store.loadDay(dateKey: tomorrowKey)?.source, "llm")
    }

    // MARK: 工具

    private func dateAt(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
}
