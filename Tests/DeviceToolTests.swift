import EventKit
import XCTest
@testable import FenShen

/// 本机信息工具测试：只覆盖纯函数（时间解析 / 窗口过滤 / 逾期 / 排序 / 格式化 / JSON 形状）。
/// EventKit 的真实读写需要系统权限和数据，不在单测范围（真机手测）；
/// 需要授权的工具一律先校验参数再申请权限，因此可以安全地测非法参数分支。
final class DeviceToolTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private func makeDate(_ year: Int, _ month: Int, _ day: Int,
                          _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: year, month: month, day: day,
                                             hour: hour, minute: minute))!
    }

    private func dateAt(_ clock: String, on day: Date = Date()) -> Date? {
        DeviceToolDateParser.parse(clock, baseDay: day)
    }

    // MARK: 时间参数解析

    func testParseClockAssumesBaseDay() throws {
        let day = Date()
        let parsed = try XCTUnwrap(dateAt("15:30", on: day))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        let dayComps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        XCTAssertEqual(comps.year, dayComps.year)
        XCTAssertEqual(comps.hour, 15)
        XCTAssertEqual(comps.minute, 30)
    }

    func testParseFullDateTime() throws {
        let parsed = try XCTUnwrap(DeviceToolDateParser.parse("2026-12-25 09:05"))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 25)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 5)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(DeviceToolDateParser.parse("没有时间"))
        XCTAssertNil(DeviceToolDateParser.parse("25:99"))
    }

    // MARK: day 参数 → 日期

    func testDayNameResolvesToLocalMidnight() throws {
        let now = makeDate(2026, 11, 22, 17, 30)
        XCTAssertEqual(DeviceToolCalendar.day(named: "today", now: now, timeZone: timeZone),
                       makeDate(2026, 11, 22))
        XCTAssertEqual(DeviceToolCalendar.day(named: "tomorrow", now: now, timeZone: timeZone),
                       makeDate(2026, 11, 23))
        XCTAssertEqual(DeviceToolCalendar.day(named: "yesterday", now: now, timeZone: timeZone),
                       makeDate(2026, 11, 21))
        XCTAssertNil(DeviceToolCalendar.day(named: "week", now: now, timeZone: timeZone))
    }

    func testDayRangeCoversWholeLocalDay() {
        let range = DeviceToolCalendar.dayRange(of: makeDate(2026, 11, 22, 13, 0), timeZone: timeZone)
        XCTAssertEqual(range.start, makeDate(2026, 11, 22))
        XCTAssertEqual(range.end, makeDate(2026, 11, 23))
    }

    // MARK: calendar_read 多看几天（未来一周）

    func testCalendarRangeSpansRequestedDays() {
        let week = DeviceToolCalendar.range(of: makeDate(2026, 11, 22, 13, 0), days: 7, timeZone: timeZone)
        XCTAssertEqual(week.start, makeDate(2026, 11, 22), "窗口从当天零点开始")
        XCTAssertEqual(week.end, makeDate(2026, 11, 29), "7 天窗口到第 8 天零点")
        let single = DeviceToolCalendar.range(of: makeDate(2026, 11, 22, 13, 0), days: 0, timeZone: timeZone)
        XCTAssertEqual(single.end, makeDate(2026, 11, 23), "不足 1 天按 1 天")
    }

    func testClampCalendarDays() {
        XCTAssertEqual(DeviceToolCalendar.clampDays(nil), 1)
        XCTAssertEqual(DeviceToolCalendar.clampDays(0), 1)
        XCTAssertEqual(DeviceToolCalendar.clampDays(0.5), 1)
        XCTAssertEqual(DeviceToolCalendar.clampDays(7), 7)
        XCTAssertEqual(DeviceToolCalendar.clampDays(7.9), 7)
        XCTAssertEqual(DeviceToolCalendar.clampDays(31), 30)
        XCTAssertEqual(DeviceToolCalendar.clampDays(.infinity), 1)
    }

    func testCalendarReadArgsDecoding() {
        let week = CalendarReadArgs.decode(#"{"day": "today", "days": 7}"#)
        XCTAssertEqual(week.day, "today")
        XCTAssertEqual(week.days, 7)

        let empty = CalendarReadArgs.decode("{}")
        XCTAssertNil(empty.day)
        XCTAssertNil(empty.days)

        let wrongTypes = CalendarReadArgs.decode(#"{"day": 1, "days": "7"}"#)
        XCTAssertNil(wrongTypes.day)
        XCTAssertNil(wrongTypes.days)

        let garbage = CalendarReadArgs.decode("不是 JSON")
        XCTAssertNil(garbage.day)
        XCTAssertNil(garbage.days)
    }

    // MARK: calendar_read 多天文本：按天分组 / 空日子 / 截断

    func testMultiDayEventsTextGroupsByDayAndMarksEmptyDays() {
        let start = makeDate(2026, 11, 22)
        let end = makeDate(2026, 11, 29)
        let events = [
            DeviceEventItem(id: "e1", calendar: "工作", title: "周会",
                            start: makeDate(2026, 11, 22, 9, 0), end: makeDate(2026, 11, 22, 10, 0),
                            allDay: false, location: "三楼"),
            DeviceEventItem(id: "e2", calendar: "个人", title: "体检",
                            start: makeDate(2026, 11, 24, 8, 30), end: makeDate(2026, 11, 24, 10, 30),
                            allDay: false, location: ""),
        ]
        let text = DeviceToolFormatter.multiDayEventsText(events, from: start, to: end, timeZone: timeZone)
        XCTAssertTrue(text.contains("查询范围：11/22 周日 – 11/28 周六（7 天，共 2 个日程）"), "范围标题：\(text)")
        XCTAssertTrue(text.contains("11/22 周日\n· 09:00–10:00 周会（三楼）（日历「工作」）"), "首日分组：\(text)")
        XCTAssertTrue(text.contains("11/23 周一（没有日程）"), "空日子要写出来：\(text)")
        XCTAssertTrue(text.contains("· 08:30–10:30 体检（日历「个人」）"), "事件行：\(text)")
    }

    func testMultiDayEventsTextEmptyRange() {
        let start = makeDate(2026, 11, 22)
        let end = makeDate(2026, 11, 29)
        let text = DeviceToolFormatter.multiDayEventsText([], from: start, to: end, timeZone: timeZone)
        XCTAssertTrue(text.contains("查询范围：11/22 周日 – 11/28 周六（7 天，共 0 个日程）"), "范围标题：\(text)")
        XCTAssertTrue(text.contains("这几天日历上是空的。"), "整段为空要明说：\(text)")
    }

    func testMultiDayEventsTextTruncatesWithNote() {
        let start = makeDate(2026, 11, 22)
        let end = makeDate(2026, 11, 25)
        let many = (0..<(DeviceToolFormatter.maxMultiDayLines + 2)).map { index in
            DeviceEventItem(id: "e\(index)", calendar: "工作", title: "会\(index)",
                            start: makeDate(2026, 11, 22, 9, 0), end: makeDate(2026, 11, 22, 10, 0),
                            allDay: false, location: "")
        }
        let text = DeviceToolFormatter.multiDayEventsText(many, from: start, to: end, timeZone: timeZone)
        XCTAssertTrue(text.contains("还有 2 个日程没显示"), "超上限要明确告知：\(text)")
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("· ") }.count,
                       DeviceToolFormatter.maxMultiDayLines)
    }

    // MARK: days_ahead / 窗口

    func testClampDaysAhead() {
        XCTAssertEqual(ApplePIMSemantics.clampDaysAhead(nil), 0)
        XCTAssertEqual(ApplePIMSemantics.clampDaysAhead(-3), 0)
        XCTAssertEqual(ApplePIMSemantics.clampDaysAhead(0), 0)
        XCTAssertEqual(ApplePIMSemantics.clampDaysAhead(2.9), 2)
        XCTAssertEqual(ApplePIMSemantics.clampDaysAhead(30.7), 30)
        XCTAssertEqual(ApplePIMSemantics.clampDaysAhead(31), 30)
        XCTAssertEqual(ApplePIMSemantics.clampDaysAhead(.infinity), 0)
    }

    func testWindowStartsAtLocalMidnightAndSpansHorizon() {
        let now = makeDate(2026, 11, 22, 17, 0)
        let today = ApplePIMSemantics.window(now: now, daysAhead: 0, timeZone: timeZone)
        XCTAssertEqual(today.start, makeDate(2026, 11, 22))
        XCTAssertEqual(today.end, makeDate(2026, 11, 23))

        let threeDays = ApplePIMSemantics.window(now: now, daysAhead: 2, timeZone: timeZone)
        XCTAssertEqual(threeDays.end, makeDate(2026, 11, 25))

        let clamped = ApplePIMSemantics.window(now: now, daysAhead: 30, timeZone: timeZone)
        XCTAssertEqual(clamped.end, makeDate(2026, 12, 23))
    }

    // MARK: 逾期判定（对齐桌面 reminders.applescript:47：due < 今天零点）

    func testOverdueUsesStartOfDay() {
        let now = makeDate(2026, 11, 22, 17, 0)
        XCTAssertTrue(ApplePIMSemantics.isOverdue(makeDate(2026, 11, 21, 23, 59), now: now, timeZone: timeZone))
        XCTAssertFalse(ApplePIMSemantics.isOverdue(makeDate(2026, 11, 22), now: now, timeZone: timeZone))
        // 今天更早时刻到期不算逾期（桌面端按「今天零点」判断）
        XCTAssertFalse(ApplePIMSemantics.isOverdue(makeDate(2026, 11, 22, 9, 0), now: now, timeZone: timeZone))
        XCTAssertFalse(ApplePIMSemantics.isOverdue(nil, now: now, timeZone: timeZone))
    }

    // MARK: 提醒窗口过滤

    func testFilterRemindersKeepsOverdueTodayAndHorizon() {
        let now = makeDate(2026, 11, 22, 9, 0)
        let items = [
            DeviceReminderItem(id: "overdue", title: "逾期", list: "L", due: makeDate(2026, 11, 21, 18, 0)),
            DeviceReminderItem(id: "today", title: "今天", list: "L", due: makeDate(2026, 11, 22, 18, 0)),
            DeviceReminderItem(id: "tomorrow", title: "明天", list: "L", due: makeDate(2026, 11, 23, 9, 0)),
            DeviceReminderItem(id: "outside", title: "窗口外", list: "L", due: makeDate(2026, 11, 24)),
            DeviceReminderItem(id: "no-due", title: "无截止", list: "L", due: nil),
        ]
        let oneDay = ApplePIMSemantics.filterReminders(items, now: now, daysAhead: 1, timeZone: timeZone)
        XCTAssertEqual(Set(oneDay.map(\.id)), ["overdue", "today", "tomorrow", "no-due"],
                       "窗口 = [今天0点, 今天0点+(1+N)天)，到期日恰在结束边界的不收")

        let todayOnly = ApplePIMSemantics.filterReminders(items, now: now, daysAhead: 0, timeZone: timeZone)
        XCTAssertEqual(Set(todayOnly.map(\.id)), ["overdue", "today", "no-due"])
    }

    func testFilterRemindersKeepsNoDueItemsLast() {
        let now = makeDate(2026, 11, 22, 9, 0)
        let items = [
            DeviceReminderItem(id: "a", title: "无截止", list: "L", due: nil),
            DeviceReminderItem(id: "b", title: "逾期", list: "L", due: makeDate(2026, 11, 20, 8, 0)),
        ]
        let kept = ApplePIMSemantics.filterReminders(items, now: now, daysAhead: 0, timeZone: timeZone)
        XCTAssertEqual(kept.count, 2, "无截止时间的提醒保留（intentional 偏差，避免永远看不见）")
    }

    // MARK: 提醒排序

    func testSortRemindersOverdueThenTodayThenFutureThenNoDue() {
        let items = [
            DeviceReminderItem(id: "future", title: "未来", list: "L", due: makeDate(2026, 11, 23, 10, 0)),
            DeviceReminderItem(id: "overdue-late", title: "逾期晚", list: "L", due: makeDate(2026, 11, 21, 9, 0)),
            DeviceReminderItem(id: "no-due", title: "无截止", list: "L", due: nil),
            DeviceReminderItem(id: "today", title: "今天", list: "L", due: makeDate(2026, 11, 22, 8, 0)),
            DeviceReminderItem(id: "overdue-early", title: "逾期早", list: "L", due: makeDate(2026, 11, 21, 7, 0)),
        ]
        let sorted = ApplePIMSemantics.sortReminders(items)
        XCTAssertEqual(sorted.map(\.id), ["overdue-early", "overdue-late", "today", "future", "no-due"])
    }

    // MARK: 事件窗口过滤 / 排序

    func testFilterEventsUsesHalfOpenWindow() {
        let now = makeDate(2026, 11, 22, 12, 0)
        let items = [
            DeviceEventItem(id: "inside", calendar: "个人", title: "周会",
                            start: makeDate(2026, 11, 22, 10, 0), end: makeDate(2026, 11, 22, 11, 0),
                            allDay: false, location: ""),
            DeviceEventItem(id: "all-day", calendar: "个人", title: "团建",
                            start: makeDate(2026, 11, 22), end: makeDate(2026, 11, 23),
                            allDay: true, location: ""),
            DeviceEventItem(id: "ends-at-start", calendar: "个人", title: "昨天结束",
                            start: makeDate(2026, 11, 21, 23, 0), end: makeDate(2026, 11, 22),
                            allDay: false, location: ""),
            DeviceEventItem(id: "starts-at-end", calendar: "个人", title: "明天开始",
                            start: makeDate(2026, 11, 23), end: makeDate(2026, 11, 23, 1, 0),
                            allDay: false, location: ""),
            DeviceEventItem(id: "tomorrow", calendar: "个人", title: "明天",
                            start: makeDate(2026, 11, 23, 9, 0), end: makeDate(2026, 11, 23, 10, 0),
                            allDay: false, location: ""),
        ]
        let today = ApplePIMSemantics.filterEvents(items, now: now, daysAhead: 0, timeZone: timeZone)
        XCTAssertEqual(Set(today.map(\.id)), ["inside", "all-day"],
                       "与 [今天0点, 明天0点) 相交才收，边界相接不算")

        let twoDays = ApplePIMSemantics.filterEvents(items, now: now, daysAhead: 1, timeZone: timeZone)
        XCTAssertEqual(Set(twoDays.map(\.id)), ["inside", "all-day", "starts-at-end", "tomorrow"],
                       "两天窗口到 11/24 零点为止，11/23 零点开始的「明天开始」在窗口内；"
                       + "边界相接不算只针对窗口自己的 end")
    }

    func testSortEventsByStartThenTieBreakers() {
        let items = [
            DeviceEventItem(id: "b", calendar: "工作", title: "B",
                            start: makeDate(2026, 11, 22, 11, 0), end: makeDate(2026, 11, 22, 12, 0),
                            allDay: false, location: ""),
            DeviceEventItem(id: "a", calendar: "个人", title: "A",
                            start: makeDate(2026, 11, 22, 9, 0), end: makeDate(2026, 11, 22, 10, 0),
                            allDay: false, location: ""),
        ]
        XCTAssertEqual(ApplePIMSemantics.sortEvents(items).map(\.id), ["a", "b"])
    }

    // MARK: calendar_read 文本：全天 / 跨天 / 日历名

    func testEventsTextShowsAllDayInsteadOfMidnight() throws {
        let event = DeviceEventItem(id: "e1", calendar: "个人", title: "团建",
                                    start: makeDate(2026, 11, 22), end: makeDate(2026, 11, 23),
                                    allDay: true, location: "")
        let text = DeviceToolFormatter.eventsText([event], timeZone: timeZone)
        XCTAssertTrue(text.contains("全天 团建"), "全天事件应显示「全天」：\(text)")
        XCTAssertTrue(text.contains("（日历「个人」）"), "应带日历名：\(text)")
        XCTAssertFalse(text.contains("00:00–00:00"), "不应把全天事件渲染成 00:00–00:00：\(text)")
    }

    func testEventsTextShowsCrossDayWithDates() throws {
        let event = DeviceEventItem(id: "e1", calendar: "工作", title: "出差",
                                    start: makeDate(2026, 11, 22, 22, 0),
                                    end: makeDate(2026, 11, 23, 2, 0),
                                    allDay: false, location: "杭州")
        let text = DeviceToolFormatter.eventsText([event], timeZone: timeZone)
        XCTAssertTrue(text.contains("11/22 22:00 – 11/23 02:00 出差（杭州）（日历「工作」）"), "跨天应带日期：\(text)")
    }

    func testEventsTextSameDayAndEmpty() {
        XCTAssertEqual(DeviceToolFormatter.eventsText([], timeZone: timeZone), "那天日历上是空的。")

        let start = makeDate(2026, 11, 22, 9, 0)
        let end = makeDate(2026, 11, 22, 10, 30)
        let event = DeviceEventItem(id: "e1", calendar: "工作", title: "周会",
                                    start: start, end: end, allDay: false, location: "三楼会议室")
        let text = DeviceToolFormatter.eventsText([event], timeZone: timeZone)
        XCTAssertTrue(text.contains("09:00–10:30 周会（三楼会议室）（日历「工作」）"), "同天格式：\(text)")
    }

    // MARK: apple_pim_today 参数解码（容错）

    func testTodayArgsDecoding() {
        let full = ApplePIMTodayArgs.decode(#"{"days_ahead": 3, "include_reminders": false, "include_calendar": true}"#)
        XCTAssertEqual(full.daysAhead, 3)
        XCTAssertEqual(full.includeReminders, false)
        XCTAssertEqual(full.includeCalendar, true)

        let empty = ApplePIMTodayArgs.decode("{}")
        XCTAssertNil(empty.daysAhead)
        XCTAssertNil(empty.includeReminders)
        XCTAssertNil(empty.includeCalendar)

        let wrongTypes = ApplePIMTodayArgs.decode(#"{"days_ahead": "3", "include_reminders": "no"}"#)
        XCTAssertNil(wrongTypes.daysAhead, "days_ahead 只认数字（桌面端 typeof number）")
        XCTAssertNil(wrongTypes.includeReminders)

        let garbage = ApplePIMTodayArgs.decode("不是 JSON")
        XCTAssertNil(garbage.daysAhead)
        XCTAssertNil(garbage.includeCalendar)
    }

    // MARK: apple_pim_today JSON 输出形状

    func testDigestJSONShapeAndFieldOrder() {
        let now = makeDate(2026, 11, 22, 17, 0)
        let reminders = [
            DeviceReminderItem(id: "r2", title: "买牛奶", list: "提醒事项", due: makeDate(2026, 11, 21, 18, 0)),
            DeviceReminderItem(id: "r1", title: "交周报", list: "工作", due: nil),
        ]
        let events = [
            DeviceEventItem(id: "e1", calendar: "个人", title: "周会",
                            start: makeDate(2026, 11, 22, 10, 0), end: makeDate(2026, 11, 22, 11, 0),
                            allDay: false, location: "三楼会议室"),
            DeviceEventItem(id: "e2", calendar: "个人", title: "团建",
                            start: makeDate(2026, 11, 22), end: makeDate(2026, 11, 23),
                            allDay: true, location: ""),
        ]
        let json = ApplePIMJSON.digest(now: now, timeZone: timeZone,
                                       reminders: reminders, events: events,
                                       errors: ["calendar: 读取失败"])
        let expected = """
        {"date":"2026年11月22日星期日","timeZone":"Asia/Shanghai",\
        "reminders":[\
        {"id":"r2","title":"买牛奶","list":"提醒事项","due":"2026-11-21T18:00:00","overdue":true},\
        {"id":"r1","title":"交周报","list":"工作","due":"","overdue":false}],\
        "events":[\
        {"id":"e1","calendar":"个人","title":"周会","start":"2026-11-22T02:00:00.000Z","end":"2026-11-22T03:00:00.000Z","allDay":false,"location":"三楼会议室"},\
        {"id":"e2","calendar":"个人","title":"团建","start":"2026-11-21T16:00:00.000Z","end":"2026-11-22T16:00:00.000Z","allDay":true,"location":""}],\
        "errors":["calendar: 读取失败"]}
        """
        XCTAssertEqual(json, expected, "字段名/顺序/时间格式应与桌面端 schema 一致")
    }

    func testDigestJSONIsParseableEndToEnd() throws {
        let now = makeDate(2026, 11, 22, 9, 0)
        let reminders = [
            DeviceReminderItem(id: "r1", title: "带\"引号\"和\n换行", list: "L", due: makeDate(2026, 11, 22, 18, 0)),
        ]
        let events = [
            DeviceEventItem(id: "e1", calendar: "C", title: "事件", start: now, end: now.addingTimeInterval(3_600),
                            allDay: false, location: ""),
        ]
        let json = ApplePIMJSON.digest(now: now, timeZone: timeZone,
                                       reminders: reminders, events: events, errors: [])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["date", "timeZone", "reminders", "events", "errors"])
        let parsedReminders = try XCTUnwrap(object["reminders"] as? [[String: Any]])
        XCTAssertEqual(parsedReminders.first?["title"] as? String, "带\"引号\"和\n换行", "JSON 字符串转义要正确")
        XCTAssertEqual(parsedReminders.first?["overdue"] as? Bool, false, "今天到期的提醒不算逾期")
        XCTAssertEqual(parsedReminders.first?["due"] as? String, "2026-11-22T18:00:00")
        let parsedEvents = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(parsedEvents.first?["allDay"] as? Bool, false)
    }

    // MARK: 参数校验（在校验阶段就返回，不申请权限 → 单测安全）

    func testCalendarCreateToolWithoutTitleReturnsReadableError() async {
        let result = await CalendarCreateTool().run(argumentsJSON: #"{"start": "15:00"}"#)
        XCTAssertTrue(result.contains("title"), "缺 title 应在错误里点名：\(result)")
    }

    func testCalendarCreateRejectsEndNotAfterStart() async {
        let result = await CalendarCreateTool().run(
            argumentsJSON: #"{"title": "开会", "start": "2026-11-23 15:00", "end": "2026-11-23 14:00"}"#)
        XCTAssertTrue(result.contains("结束时间必须晚于开始时间"), "应明确报错：\(result)")
        XCTAssertFalse(result.contains("已写入"), "校验失败不能写入：\(result)")
    }

    func testCalendarCreateRejectsUnparseableTimes() async {
        let badStart = await CalendarCreateTool().run(argumentsJSON: #"{"title": "开会", "start": "25:99"}"#)
        XCTAssertTrue(badStart.contains("开始时间没看懂"), "应报开始时间错误：\(badStart)")

        let badEnd = await CalendarCreateTool().run(
            argumentsJSON: #"{"title": "开会", "start": "15:00", "end": "看不太懂"}"#)
        XCTAssertTrue(badEnd.contains("结束时间没看懂"), "应报结束时间错误：\(badEnd)")
    }

    func testRemindersCreateRejectsUnparseableDueWithoutCreating() async {
        let result = await RemindersCreateTool().run(
            argumentsJSON: #"{"title": "买牛奶", "due": "明天上午"}"#)
        XCTAssertTrue(result.contains("到期时间没看懂"), "非法 due 应报错：\(result)")
        XCTAssertTrue(result.contains("未创建任何提醒"), "不应静默创建：\(result)")
        XCTAssertFalse(result.contains("已加入"), "校验失败不能创建：\(result)")
    }
}
