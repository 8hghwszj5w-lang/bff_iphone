import XCTest
import Foundation
@testable import FenShen

/// 只测生产实现共用的生命周期/结果状态；不创建 AVAudioEngine，也不请求系统权限。
final class SpeechSessionTests: XCTestCase {
    private func eventValue(_ event: STTEvent?) -> String? {
        guard let event else { return nil }
        switch event {
        case .partial(let text): return "partial:\(text)"
        case .final(let text): return "final:\(text)"
        }
    }

    func testStartReservesSessionBeforeAsynchronousPreparation() throws {
        var lifecycle = SpeechSessionLifecycle()
        let id = try XCTUnwrap(lifecycle.beginStart())

        XCTAssertTrue(lifecycle.isCurrent(id))
        XCTAssertFalse(lifecycle.isCurrent(id, requiringRunning: true))
        XCTAssertNil(lifecycle.beginStart(), "权限或模型下载尚未完成时，重复 start 也不能创建第二次会话")
        XCTAssertTrue(lifecycle.markRunning(id))
        XCTAssertTrue(lifecycle.isCurrent(id, requiringRunning: true))
        XCTAssertNil(lifecycle.beginStart())
    }

    func testStopDuringPreparationRejectsLateStartup() throws {
        var lifecycle = SpeechSessionLifecycle()
        let pending = try XCTUnwrap(lifecycle.beginStart())

        XCTAssertTrue(lifecycle.invalidate())
        XCTAssertFalse(lifecycle.markRunning(pending), "权限/下载迟到完成不能在 stop 后重新开启麦克风")
        XCTAssertFalse(lifecycle.isCurrent(pending))
        XCTAssertFalse(lifecycle.isRunning)
    }

    func testOldCancellationCannotStopReplacementSession() throws {
        var lifecycle = SpeechSessionLifecycle()
        let old = try XCTUnwrap(lifecycle.beginStart())
        lifecycle.invalidate()
        let current = try XCTUnwrap(lifecycle.beginStart())
        lifecycle.markRunning(current)

        XCTAssertNotEqual(old, current)
        XCTAssertFalse(lifecycle.invalidate(ifCurrent: old), "旧启动任务的取消或 catch 不能清理新会话")
        XCTAssertFalse(lifecycle.markRunning(old))
        XCTAssertTrue(lifecycle.isCurrent(current, requiringRunning: true))
    }

    func testStopIsIdempotentAndAllowsAnotherStart() throws {
        var lifecycle = SpeechSessionLifecycle()
        let first = try XCTUnwrap(lifecycle.beginStart())
        lifecycle.markRunning(first)

        XCTAssertTrue(lifecycle.invalidate(ifCurrent: first))
        XCTAssertFalse(lifecycle.invalidate())
        XCTAssertFalse(lifecycle.isRunning)
        let next = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertNotEqual(first, next)
        XCTAssertTrue(lifecycle.markRunning(next))
    }

    func testSameTextPartialDoesNotSuppressFinal() {
        var state = LegacySpeechRecognitionState()
        let round = state.beginRound()

        XCTAssertEqual(eventValue(state.consume(text: "你好", isFinal: false, roundID: round)), "partial:你好")
        XCTAssertEqual(eventValue(state.consume(text: "你好", isFinal: true, roundID: round)), "final:你好",
                       "final 必须在文本去重前处理，否则最常见的同文最终结果会被吞掉")
        XCTAssertNil(state.roundID, "final 后解除本轮占用，允许创建新 request")
    }

    func testOnlyRepeatedPartialsAreDeduplicated() {
        var state = LegacySpeechRecognitionState()
        let round = state.beginRound()

        XCTAssertEqual(eventValue(state.consume(text: "你", isFinal: false, roundID: round)), "partial:你")
        XCTAssertNil(state.consume(text: "你", isFinal: false, roundID: round))
        XCTAssertEqual(eventValue(state.consume(text: "你好", isFinal: false, roundID: round)), "partial:你好")
        XCTAssertEqual(state.roundID, round)
    }

    func testFinalDeliveredOnceAndLatePartialsIgnored() {
        var state = LegacySpeechRecognitionState()
        let round = state.beginRound()

        XCTAssertEqual(eventValue(state.consume(text: "结束", isFinal: true, roundID: round)), "final:结束")
        XCTAssertNil(state.consume(text: "结束", isFinal: true, roundID: round), "重复 final 不能重复交付或重复安排重启")
        XCTAssertNil(state.consume(text: "迟到字幕", isFinal: false, roundID: round))
    }

    func testNextRoundCanRepeatSameSentence() {
        var state = LegacySpeechRecognitionState()
        let first = state.beginRound()
        _ = state.consume(text: "你好", isFinal: false, roundID: first)
        _ = state.consume(text: "你好", isFinal: true, roundID: first)
        let second = state.beginRound()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(eventValue(state.consume(text: "你好", isFinal: false, roundID: second)), "partial:你好")
        XCTAssertEqual(eventValue(state.consume(text: "你好", isFinal: true, roundID: second)), "final:你好")
    }

    func testOldRoundCannotEmitOrInvalidateCurrentRound() {
        var state = LegacySpeechRecognitionState()
        let first = state.beginRound()
        _ = state.consume(text: "第一句", isFinal: true, roundID: first)
        let second = state.beginRound()

        XCTAssertNil(state.consume(text: "旧结果", isFinal: true, roundID: first))
        XCTAssertNil(state.consume(text: "旧字幕", isFinal: false, roundID: first))
        XCTAssertEqual(state.roundID, second)
        XCTAssertEqual(eventValue(state.consume(text: "第二句", isFinal: true, roundID: second)), "final:第二句")
    }

    func testStopInvalidatesResultsAndPendingRestart() throws {
        var lifecycle = SpeechSessionLifecycle()
        var state = LegacySpeechRecognitionState()
        let session = try XCTUnwrap(lifecycle.beginStart())
        lifecycle.markRunning(session)
        let round = state.beginRound()
        _ = state.consume(text: "你好", isFinal: true, roundID: round)

        // final 已排队安排下一轮，此时用户挂断。
        lifecycle.invalidate()
        state.invalidate()
        XCTAssertFalse(lifecycle.isCurrent(session, requiringRunning: true), "排队中的重启必须被 stop 拦住")
        XCTAssertNil(state.consume(text: "迟到 final", isFinal: true, roundID: round))

        // 用户又开启新通话，旧重启仍必须失效。
        let next = try XCTUnwrap(lifecycle.beginStart())
        lifecycle.markRunning(next)
        XCTAssertFalse(lifecycle.isCurrent(session, requiringRunning: true))
        XCTAssertTrue(lifecycle.isCurrent(next, requiringRunning: true))
    }

    func testStopBeforeFinalRejectsLateFinal() {
        var state = LegacySpeechRecognitionState()
        let round = state.beginRound()
        _ = state.consume(text: "还没说完", isFinal: false, roundID: round)
        state.invalidate()

        XCTAssertNil(state.consume(text: "还没说完", isFinal: true, roundID: round))
        XCTAssertNil(state.roundID)
    }
}
