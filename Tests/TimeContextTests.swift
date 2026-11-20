import XCTest
@testable import FenShen

/// 时间上下文测试：戳格式 / 间隔分桶 / 拼装顺序
final class TimeContextTests: XCTestCase {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi
        return Calendar.current.date(from: comps)!
    }

    func testStampFormat() {
        let stamp = TimeContext.turnStamp(for: date(2026, 11, 20, 17, 5))
        XCTAssertTrue(stamp.hasPrefix("［2026-11-20 17:05 "), "应为全角括号 + yyyy-MM-dd HH:mm：\(stamp)")
        XCTAssertTrue(stamp.hasSuffix("］"))
        XCTAssertTrue(stamp.contains("周"), "应含星期（周X）")
    }

    func testGapTextBuckets() {
        let base = date(2026, 11, 20, 10, 0)
        XCTAssertNil(TimeContext.gapText(from: base.addingTimeInterval(-240), to: base),
                     "5 分钟内视为连续聊天，不注入")
        XCTAssertEqual(TimeContext.gapText(from: base.addingTimeInterval(-600), to: base),
                       "距上一条已过去 10 分钟")
        XCTAssertEqual(TimeContext.gapText(from: base.addingTimeInterval(-2 * 3600 - 15 * 60), to: base),
                       "距上一条已过去 2 小时 15 分钟")
        XCTAssertEqual(TimeContext.gapText(from: base.addingTimeInterval(-2 * 3600), to: base),
                       "距上一条已过去 2 小时")
        XCTAssertEqual(TimeContext.gapText(from: base.addingTimeInterval(-3 * 86400 - 5 * 3600), to: base),
                       "距上一条已过去 3 天 5 小时")
        XCTAssertEqual(TimeContext.gapText(from: base.addingTimeInterval(-3 * 86400), to: base),
                       "距上一条已过去 3 天")
        XCTAssertNil(TimeContext.gapText(from: nil, to: base), "无上一条时不注入")
    }

    func testStampedUserMessageOrder() {
        let prev = date(2026, 11, 20, 9, 0)
        let now = date(2026, 11, 20, 17, 5)
        let stamped = TimeContext.stampedUserMessage("在吗", previousMessageTime: prev, now: now)
        XCTAssertTrue(stamped.hasPrefix("［"), "时间戳在最前")
        XCTAssertTrue(stamped.contains("距上一条已过去 8 小时 5 分钟"))
        XCTAssertTrue(stamped.hasSuffix("在吗"), "正文在最后")

        // 正文为空（语音/纯附件轮）时保留完整前缀，不留悬空空格
        let empty = TimeContext.stampedUserMessage("", previousMessageTime: prev, now: now)
        XCTAssertEqual(empty, "［2026-11-20 17:05 周五］（距上一条已过去 8 小时 5 分钟）")
    }
}
