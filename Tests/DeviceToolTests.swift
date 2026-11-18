import EventKit
import XCTest
@testable import FenShen

/// 本机信息工具测试：只覆盖纯函数（时间解析 / 格式化 / 参数解码）。
/// EventKit/Spotlight 的真实读写需要系统权限和数据，不在单测范围（真机手测）。
final class DeviceToolTests: XCTestCase {
    private func dateAt(_ clock: String, on day: Date = Date()) -> Date? {
        DeviceToolDateParser.parse(clock, baseDay: day)
    }
    private let day = Date()

    // MARK: 时间参数解析

    func testParseClockAssumesBaseDay() throws {
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

    // MARK: 格式化

    func testEventsTextEmptyAndFilled() throws {
        XCTAssertEqual(DeviceToolFormatter.eventsText([]), "那天日历上是空的。")

        let start = try XCTUnwrap(dateAt("09:00"))
        let end = try XCTUnwrap(dateAt("10:30"))
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "周会"
        event.location = "三楼会议室"
        event.startDate = start
        event.endDate = end
        let text = DeviceToolFormatter.eventsText([event])
        XCTAssertTrue(text.contains("09:00–10:30 周会（三楼会议室）"), "应格式化为 时间 标题（地点）：\(text)")
    }

    func testRemindersTextShowsDue() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "买牛奶"
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: try XCTUnwrap(dateAt("18:00")))
        let text = DeviceToolFormatter.remindersText([reminder])
        XCTAssertTrue(text.contains("买牛奶"), "应含标题：\(text)")
        XCTAssertTrue(text.contains("到期"), "应含到期时间：\(text)")
        XCTAssertEqual(DeviceToolFormatter.remindersText([]), "没有未完成的提醒事项。")
    }

    // MARK: 工具参数解码（缺字段要给出可读错误而不是崩溃）

    func testCalendarCreateToolWithoutTitleReturnsReadableError() async {
        let tool = CalendarCreateTool()
        let result = await tool.run(argumentsJSON: #"{"start": "15:00"}"#)
        XCTAssertTrue(result.contains("title"), "缺 title 应在错误里点名：\(result)")
    }

    func testNotesToolToleratesEmptyArgs() async {
        let tool = NotesSearchTool()
        // 不查真 Spotlight：空 query 也会走系统查询，模拟器上可能立刻返回空。
        // 这里只验证参数解码不崩（真查询在真机手测）。
        _ = await tool.run(argumentsJSON: "{}")
        _ = await tool.run(argumentsJSON: "不是 JSON")
    }
}
