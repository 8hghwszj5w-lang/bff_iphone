import XCTest
import AVFoundation
@testable import FenShen

// 覆盖两处“重复恢复续体 / 轮询等待”的回归：
// · LocalAVSpeechTTSEngine：每句一个续体，stop 或迟到回调只能结束它自己一次；
// · StreamingAudioPlayer：drain 由 dataPlayed 回调唤醒，stop 后迟到回调不能误清新一轮。
// 全部使用注入的假合成器/假输出，不创建真实音频引擎、不激活音频会话。

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() {
        lock.lock(); storage += 1; lock.unlock()
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@MainActor
private final class FakeSpeechSynthesizer: LocalSpeechSynthesizing {
    var onEvent: (@MainActor (LocalSpeechEvent, AVSpeechUtterance) -> Void)?
    private(set) var spoken: [AVSpeechUtterance] = []
    private(set) var stopCount = 0

    func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance) }
    func stop() { stopCount += 1 }
    func emit(_ event: LocalSpeechEvent, _ utterance: AVSpeechUtterance) {
        onEvent?(event, utterance)
    }
}

private final class FakeAudioOutput: StreamingAudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [@Sendable () async -> Void] = []
    private(set) var stopCount = 0
    private(set) var shutdownCount = 0

    func schedule(_ buffer: AVAudioPCMBuffer,
                  completion: @escaping @Sendable () async -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        completions.append(completion)
    }

    /// 模拟 stop：真实节点会丢弃尚未播完的 buffer，它们的回调不再有意义。
    func stop() {
        lock.lock(); completions.removeAll(); stopCount += 1; lock.unlock()
    }

    func shutdown() {
        lock.lock(); completions.removeAll(); shutdownCount += 1; lock.unlock()
    }

    /// 取出最早一片的回调但不执行（用于模拟 stop 之后才到达的迟到回调）。
    func takeOldest() -> (@Sendable () async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return completions.isEmpty ? nil : completions.removeFirst()
    }

    /// 模拟 dataPlayedBack：触发最早一片
    @discardableResult
    func fireOldest() -> Bool {
        guard let completion = takeOldest() else { return false }
        Task { await completion() }
        return true
    }
}

@MainActor
final class AudioLifecycleTests: XCTestCase {
    private func waitUntil(_ message: String, timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 本地 TTS 续体

    func testSpeakReportsStartOnceAndFinishesOnDidFinish() async throws {
        let synth = FakeSpeechSynthesizer()
        let engine = LocalAVSpeechTTSEngine(synthesizer: synth)
        let starts = AtomicCounter()
        let task = Task { @MainActor in
            try await engine.speak("你好") { starts.increment() }
        }
        await waitUntil("合成器应收到一句话") { synth.spoken.count == 1 }
        let utterance = try XCTUnwrap(synth.spoken.first)

        synth.emit(.started, utterance)
        synth.emit(.started, utterance)      // 重复 didStart 只算一次
        XCTAssertEqual(starts.value, 1)

        synth.emit(.finished, utterance)
        try await task.value                  // 正常结束不抛错
        XCTAssertEqual(synth.stopCount, 0)
    }

    func testStopEndsPendingSpeechExactlyOnce() async throws {
        let synth = FakeSpeechSynthesizer()
        let engine = LocalAVSpeechTTSEngine(synthesizer: synth)
        let task = Task { @MainActor in
            try await engine.speak("第一句", onStart: nil)
        }
        await waitUntil("合成器应收到一句话") { synth.spoken.count == 1 }
        let utterance = try XCTUnwrap(synth.spoken.first)

        engine.stopSpeaking()
        engine.stopSpeaking()                 // 幂等：重复 stop 不能二次恢复续体
        do {
            try await task.value
            XCTFail("被停止的 speak 应以取消结束")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        // stop 之后才到达的 didFinish/didCancel 不能再次恢复同一续体（否则会崩溃）
        synth.emit(.finished, utterance)
        synth.emit(.cancelled, utterance)
        XCTAssertEqual(synth.stopCount, 2)
    }

    func testSpeakingAgainCancelsPreviousInsteadOfOverwritingIt() async throws {
        let synth = FakeSpeechSynthesizer()
        let engine = LocalAVSpeechTTSEngine(synthesizer: synth)
        let first = Task { @MainActor in
            try await engine.speak("第一句", onStart: nil)
        }
        await waitUntil("合成器应收到第一句") { synth.spoken.count == 1 }
        let firstUtterance = try XCTUnwrap(synth.spoken.first)

        let second = Task { @MainActor in
            try await engine.speak("第二句", onStart: nil)
        }
        await waitUntil("合成器应收到第二句") { synth.spoken.count == 2 }
        let secondUtterance = try XCTUnwrap(synth.spoken.last)

        do {
            try await first.value
            XCTFail("被新句取代的旧句应以取消结束")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        // 旧句的迟到回调不能结束正在念的新句
        synth.emit(.finished, firstUtterance)
        synth.emit(.started, secondUtterance)
        synth.emit(.finished, secondUtterance)
        try await second.value
    }

    // MARK: 流式播放器 drain

    func testAwaitDrainedResumesOnPlaybackCompletion() async throws {
        let output = FakeAudioOutput()
        let player = StreamingAudioPlayer(output: output)
        let drained = AtomicCounter()

        try await player.play(pcm: Data(repeating: 0, count: 480))
        let waiter = Task {
            await player.awaitDrained()
            drained.increment()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(drained.value, 0, "音频没播完前不应返回")

        XCTAssertTrue(output.fireOldest())
        await waitUntil("播放完成后 drain 应被唤醒") { drained.value == 1 }
        await waiter.value
    }

    func testStopAllWakesWaitersAndLateCallbackCannotDrainNextRound() async throws {
        let output = FakeAudioOutput()
        let player = StreamingAudioPlayer(output: output)

        try await player.play(pcm: Data(repeating: 0, count: 480))
        // 拿住回调不执行：稍后模拟“stop 之后才到达”的完成通知。
        let late = try XCTUnwrap(output.takeOldest())
        let drained = AtomicCounter()
        let waiter = Task {
            await player.awaitDrained()
            drained.increment()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        await player.stopAll()
        await waitUntil("stopAll 应立即唤醒 drain") { drained.value == 1 }
        await waiter.value
        XCTAssertEqual(output.stopCount, 1)

        // 新一轮：上一轮的迟到回调不能把它误判成“已播完”
        try await player.play(pcm: Data(repeating: 0, count: 960))
        let second = AtomicCounter()
        let secondWaiter = Task {
            await player.awaitDrained()
            second.increment()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await late()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(second.value, 0, "迟到回调不属于新一轮，不能提前唤醒")

        XCTAssertTrue(output.fireOldest())
        await waitUntil("新一轮真正播完后才返回") { second.value == 1 }
        await secondWaiter.value
    }

    func testCancelledDrainWaiterReturnsWithoutBlockingLaterPlayback() async throws {
        let output = FakeAudioOutput()
        let player = StreamingAudioPlayer(output: output)
        let drained = AtomicCounter()

        try await player.play(pcm: Data(repeating: 0, count: 480))
        let waiter = Task { await player.awaitDrained() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        await waiter.value                    // 取消的等待者必须返回，不能永久挂住

        // 清掉上一片（真机上打断/挂断也会这么做），再验证新一轮仍能被正常唤醒
        await player.stopAll()
        try await player.play(pcm: Data(repeating: 0, count: 480))
        let secondWaiter = Task {
            await player.awaitDrained()
            drained.increment()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(output.fireOldest())
        await waitUntil("新音频播完后 drain 应恢复") { drained.value == 1 }
        await secondWaiter.value
    }

    func testShutdownStopsOutput() async throws {
        let output = FakeAudioOutput()
        let player = StreamingAudioPlayer(output: output)
        try await player.play(pcm: Data(repeating: 0, count: 480))

        await player.shutdown()
        XCTAssertEqual(output.shutdownCount, 1)
        await player.shutdown()               // 重复退出不应崩溃
        XCTAssertEqual(output.shutdownCount, 2)
    }
}
