import XCTest
import Foundation
import AVFoundation
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

// MARK: - 音频环境事件策略（通话中闪退加固的判定核心）

/// 真机上「通话中闪退」的最大来源是打断/路由切换后引擎带失效对象继续跑。
/// 这里锁定策略矩阵：什么事件、什么收音状态下，必须结束、必须重启、还是忽略。
final class AudioEnvironmentPolicyTests: XCTestCase {
    private func action(_ event: AudioEnvironmentPolicy.Event,
                        wanted: Bool = true, running: Bool = true) -> AudioEnvironmentPolicy.Action {
        AudioEnvironmentPolicy().action(for: event, captureWanted: wanted, isRunning: running)
    }

    func testInterruptionAlwaysEndsCallWithUserMessage() {
        let began = action(.interruptionBegan)
        guard case .endAndNotify(let note) = began else {
            return XCTFail("来电打断必须结束通话并给出用户可读的说明，实际：\(began)")
        }
        XCTAssertFalse(note.isEmpty)
    }

    func testMediaServicesInvalidationEndsCallWithUserMessage() {
        // 音频服务失效后所有引擎对象作废，继续持有正是底层异常崩溃的来源。
        guard case .endAndNotify = action(.mediaServicesInvalidated) else {
            return XCTFail("媒体服务失效必须结束通话")
        }
    }

    func testRouteChangeRestartsOnlyWhileRunning() {
        guard case .restart = action(.routeChanged, wanted: true, running: true) else {
            return XCTFail("收音中的路由切换应自动重启以跟随新路由")
        }
        XCTAssertEqual(action(.routeChanged, wanted: true, running: false), .ignore,
                       "准备中的路由变化不能重启（setActive 也可能触发该通知，误杀启动中的会话）")
    }

    func testEveryEventIsIgnoredAfterHangup() {
        // 用户挂断后迟到的环境事件不能把通话「复活」或触发僵尸重启。
        for event in [AudioEnvironmentPolicy.Event.interruptionBegan,
                      .mediaServicesInvalidated,
                      .routeChanged] {
            XCTAssertEqual(action(event, wanted: false, running: true), .ignore,
                           "挂断后 \(event) 必须被忽略")
            XCTAssertEqual(action(event, wanted: false, running: false), .ignore)
        }
    }
}

// MARK: - 环境通知监听（真实 NotificationCenter 投递，不碰音频硬件）

final class AudioEnvironmentWatcherTests: XCTestCase {
    private func postAudioSessionNote(_ name: Notification.Name,
                                      userInfo: [AnyHashable: Any]?) {
        NotificationCenter.default.post(name: name,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: userInfo)
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }

    @MainActor
    func testInterruptionBeganFiresButEndedDoesNot() async {
        let began = MainActorAtomicFlag()
        let watcher = AudioEnvironmentWatcher(
            onInterruptionBegan: { began.set() },
            onRouteChanged: {},
            onMediaServicesInvalidated: {})

        postAudioSessionNote(AVAudioSession.interruptionNotification, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await waitUntil { began.value }
        XCTAssertTrue(began.value, ".began 必须触发打断回调")

        began.clear()
        postAudioSessionNote(AVAudioSession.interruptionNotification, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(began.value, ".ended 不应触发打断回调（v1 不自动续播）")
        _ = watcher
    }

    @MainActor
    func testRouteChangeAndMediaServiceLossFire() async {
        let route = MainActorAtomicFlag()
        let media = MainActorAtomicFlag()
        let watcher = AudioEnvironmentWatcher(
            onInterruptionBegan: {},
            onRouteChanged: { route.set() },
            onMediaServicesInvalidated: { media.set() })

        postAudioSessionNote(AVAudioSession.routeChangeNotification, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        postAudioSessionNote(AVAudioSession.mediaServicesWereLostNotification, userInfo: nil)
        await waitUntil { route.value && media.value }
        XCTAssertTrue(route.value, "路由变化必须触发回调")
        XCTAssertTrue(media.value, "媒体服务失效必须触发回调")
        _ = watcher
    }
}

/// 主线程观察的小旗子：监听器回调统一投回主线程后置位。
@MainActor
private final class MainActorAtomicFlag {
    private var storage = false
    func set() { storage = true }
    func clear() { storage = false }
    var value: Bool { storage }
}

// MARK: - tap 缓冲区规整器（闪退修复的离线验证）
//
// 真机断言「Audio sample data must be 16-bit signed integers」（Speech 二进制
// 中已确认）：AnalyzerInput 只收 int16，麦克风原生 float32 必须转换。
// 规整器：int16 直通、float32/int32 → int16、空帧/非法格式丢弃。
// 全部用离线构造的 AVAudioPCMBuffer，不创建引擎、不碰麦克风。
final class TapBufferConditionerTests: XCTestCase {
    private func makeBuffer(_ format: AVAudioFormat, frames: AVAudioFrameCount,
                            capacity: AVAudioFrameCount? = nil) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: capacity ?? frames))
        buffer.frameLength = frames
        return buffer
    }

    private func floatFormat(rate: Double = 48_000, channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                    channels: channels, interleaved: false))
    }

    func testInt16PassesThroughUnchanged() throws {
        let conditioner = TapBufferConditioner()
        let int16Format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                      sampleRate: 48_000, channels: 1, interleaved: true))
        let buffer = try makeBuffer(int16Format, frames: 1024)
        buffer.int16ChannelData?[0][0] = 12345
        let out = try XCTUnwrap(conditioner.conditioned(buffer))
        XCTAssertTrue(out === buffer, "int16 正是 AnalyzerInput 要的格式，应原样直通")
        XCTAssertEqual(out.int16ChannelData?[0][0], 12345)
    }

    func testEmptyBufferIsDropped() throws {
        let conditioner = TapBufferConditioner()
        // 格式重协商瞬间 tap 会产出 0 帧 buffer——AnalyzerInput 对此硬 trap
        let empty = try makeBuffer(try floatFormat(), frames: 0, capacity: 1024)
        XCTAssertNil(conditioner.conditioned(empty), "空帧必须丢弃，不能喂给 Speech 框架")
    }

    func testFloat32IsConvertedToInt16() throws {
        let conditioner = TapBufferConditioner()
        // 麦克风常态：48kHz 单声道 float32 → 必须转成 int16 才能喂 AnalyzerInput
        let buffer = try makeBuffer(try floatFormat(), frames: 4)
        let samples: [Float] = [0, 0.5, 1.0, -1.0]
        for (i, s) in samples.enumerated() { buffer.floatChannelData?[0][i] = s }

        let out = try XCTUnwrap(conditioner.conditioned(buffer), "float32 应被转换而不是丢弃（否则麦克风静默死掉）")
        XCTAssertEqual(out.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(out.format.sampleRate, 48_000, "采样率保持不变，重采样由 SpeechAnalyzer 内部负责")
        XCTAssertEqual(out.frameLength, 4)
        XCTAssertEqual(out.int16ChannelData?[0][0], 0)
        XCTAssertEqual(out.int16ChannelData?[0][1], 16384)
        XCTAssertEqual(out.int16ChannelData?[0][2], 32767, "满幅 1.0 应削波到 Int16.max")
        XCTAssertEqual(out.int16ChannelData?[0][3], -32768)
    }

    func testFloat32DeinterleavedStereoBecomesInterleavedInt16() throws {
        let conditioner = TapBufferConditioner()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try makeBuffer(format, frames: 2)
        buffer.floatChannelData?[0][0] = 0.5    // 左 0
        buffer.floatChannelData?[0][1] = 0      // 左 1
        buffer.floatChannelData?[1][0] = -0.5   // 右 0
        buffer.floatChannelData?[1][1] = 0.25   // 右 1

        let out = try XCTUnwrap(conditioner.conditioned(buffer))
        XCTAssertEqual(out.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(out.format.channelCount, 2)
        XCTAssertTrue(out.format.isInterleaved, "输出应为 interleaved int16（标准 PCM 线格式）")
        XCTAssertEqual(out.int16ChannelData?[0][0], 16384)
        XCTAssertEqual(out.int16ChannelData?[0][1], -16384)
        XCTAssertEqual(out.int16ChannelData?[0][2], 0)
        XCTAssertEqual(out.int16ChannelData?[0][3], 8192)
    }

    func testInt32InterleavedStereoIsConvertedToInt16() throws {
        let conditioner = TapBufferConditioner()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt32,
                                                 sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try makeBuffer(format, frames: 2)
        buffer.int32ChannelData?[0][0] = Int32.max   // 左声道
        buffer.int32ChannelData?[0][1] = Int32.min   // 右声道
        buffer.int32ChannelData?[0][2] = 0
        buffer.int32ChannelData?[0][3] = 1 << 30     // 精确映射到 16384

        let out = try XCTUnwrap(conditioner.conditioned(buffer))
        XCTAssertEqual(out.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(out.format.channelCount, 2)
        XCTAssertEqual(out.int16ChannelData?[0][0], 32767)
        XCTAssertEqual(out.int16ChannelData?[0][1], -32768)
        XCTAssertEqual(out.int16ChannelData?[0][2], 0)
        XCTAssertEqual(out.int16ChannelData?[0][3], 16384)
    }

    func testConverterIsReusedAcrossBuffersAndFormatChange() throws {
        let conditioner = TapBufferConditioner()
        // 同一格式连续多片（tap 的常态）：转换器复用，每片都正确规整
        for i in 0..<5 {
            let buffer = try makeBuffer(try floatFormat(), frames: 256)
            buffer.floatChannelData?[0][0] = Float(1000 * (i + 1)) / 32768.0
            let out = try XCTUnwrap(conditioner.conditioned(buffer))
            XCTAssertEqual(out.format.commonFormat, .pcmFormatInt16)
            XCTAssertEqual(out.int16ChannelData?[0][0], Int16(1000 * (i + 1)))
        }
        // 路由切换后格式变了（采样率 16kHz）：重建转换器，仍然可用
        let buffer = try makeBuffer(try floatFormat(rate: 16_000), frames: 128)
        buffer.floatChannelData?[0][0] = -0.5
        let out = try XCTUnwrap(conditioner.conditioned(buffer))
        XCTAssertEqual(out.format.sampleRate, 16_000)
        XCTAssertEqual(out.int16ChannelData?[0][0], -16384)
        // int16 直通不受影响
        let int16Format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                      sampleRate: 16_000, channels: 1, interleaved: true))
        let passthrough = try makeBuffer(int16Format, frames: 64)
        XCTAssertTrue(try XCTUnwrap(conditioner.conditioned(passthrough)) === passthrough)
    }

    /// 分析器协商格式（zh_CN 为 16kHz int16）：48kHz float32 麦克风音频
    /// 必须重采样 + 转 int16——直接喂 48kHz 会报
    /// 「Model not available for LiveTranscription zh_CN 48,000」。
    func testNegotiatedFormatIsResampledAndConverted() throws {
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                 sampleRate: 16_000, channels: 1, interleaved: true))
        let conditioner = TapBufferConditioner(targetFormat: target)
        // DC 0.5 便于验证幅度（重采样滤波会平滑首尾，取中段比较）
        let buffer = try makeBuffer(try floatFormat(rate: 48_000), frames: 3_000)
        for i in 0..<3_000 { buffer.floatChannelData?[0][i] = 0.5 }

        let out = try XCTUnwrap(conditioner.conditioned(buffer))
        XCTAssertEqual(out.format.commonFormat, .pcmFormatInt16, "输出必须仍是 int16（AnalyzerInput 硬约束）")
        XCTAssertEqual(out.format.sampleRate, 16_000, "必须重采样到分析器协商的采样率")
        XCTAssertEqual(out.format.channelCount, 1)
        // 3000 帧 @48kHz = 62.5ms → @16kHz ≈ 1000 帧；SRC 有约 6–20 帧内部滤波
        // 延迟（下一片会补上，连续流总帧数不丢），允许余量。
        XCTAssertTrue((980...1_005).contains(Int(out.frameLength)),
                      "重采样后帧数应 ≈ 1000（允许 SRC 滤波延迟余量），实际 \(out.frameLength)")
        let mid = Int(out.frameLength) / 2
        let sample = Int(out.int16ChannelData?[0][mid] ?? 0)
        XCTAssertTrue(abs(sample - 16_384) <= 300, "DC 0.5 重采样后中段应≈16384，实际 \(sample)")
    }

    /// 输入已经是协商格式（例如引擎侧已转换）：直通零拷贝
    func testInputAlreadyInNegotiatedFormatPassesThrough() throws {
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                 sampleRate: 16_000, channels: 1, interleaved: true))
        let conditioner = TapBufferConditioner(targetFormat: target)
        let buffer = try makeBuffer(target, frames: 512)
        XCTAssertTrue(try XCTUnwrap(conditioner.conditioned(buffer)) === buffer)
    }
}
