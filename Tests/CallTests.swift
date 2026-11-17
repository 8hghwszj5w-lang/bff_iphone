import XCTest
import Foundation
@testable import FenShen

// 这些测试覆盖了什么：
// 1. SentenceSplitter 增量分句：句末标点切句、跨两次 feed 的增量拼接、
//    小数点（3.14）两侧都是数字时不当句号、flush 交出没凑满一句的尾巴。
// 2. CallViewModel 启动状态机：注入空实现闭包后 startCall 走 preparing → listening，
//    语音事件经 MockSpeechSession.onEvent 驱动；一轮结束的判定是 phase 回到 .listening
//    （lastMetrics 已记录）。
// 3. TTS 路由与降级：autoFallback 下云端抛错 → 无感降级本地出声（degraded +
//    degradationNote）；deepSeek 显式路由云端抛错 → 同样保证出声并带提示；
//    local 路由绝不请求云端合成。
// 4. Barge-in 打断：speaking 期间 partial 字幕比基线长 2+ 字 → 取消 LLM 流
//    （MockLLM.cancelled）+ 清播放器（player.stopped）→ 立即回 .listening，
//    埋点记录 interrupted，且不再念后续句子。
// 5. DeepSeekTTSStreamingEngine.ttsURL(fromBase:)：三种 baseURL 形态的端点归一化
//    （带 /v1 / 不带 /v1 / 带路径前缀），外加结尾斜杠与非法输入。
// 6. KeychainStore 写入/读取/更新/删除的往返（测试环境禁写 Keychain 时 XCTSkip）。
//
// Mock 实现说明：
// · LLMClient / TTSStreamingEngine 协议要求 Sendable → MockLLMClient、MockCloudTTS
//   用「final class + NSLock」保护可变状态，标 @unchecked Sendable；
// · TTSEngine.stopSpeaking、CallAudioPlayer.onFirstAudio 是同步非隔离成员，
//   @MainActor 类无法直接满足 → 这两个 Mock 用普通类，仅把 async 成员标 @MainActor
//   保证状态读写都落在主线程（VM 与测试均在 MainActor 上）；
// · SpeechSession 协议本身就是 @MainActor → MockSpeechSession 整类标 @MainActor。

// MARK: - Mock 组件

/// LLM 流式客户端 Mock：按脚本逐个 yield 文本增量（增量间可配置延迟模拟流式）。
/// 通过 AsyncThrowingStream.onTermination 的 .cancelled 捕获「流被消费方取消」，
/// 暴露 cancelled 供打断断言（正常跑完的 .finished 不算取消）。
final class MockLLMClient: LLMClient, @unchecked Sendable {
    private let script: [String]
    private let delayNanos: UInt64
    private let lock = NSLock()
    private var cancelledFlag = false

    /// - Parameters:
    ///   - script: 依次 yield 的文本增量
    ///   - delayMsPerDelta: 相邻增量之间的间隔毫秒数，0 表示立即吐完
    init(script: [String], delayMsPerDelta: UInt64 = 0) {
        self.script = script
        self.delayNanos = delayMsPerDelta * 1_000_000
    }

    /// LLM 流是否被打断取消
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    private func markCancelled() {
        lock.lock(); cancelledFlag = true; lock.unlock()
    }

    func streamReply(userText: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for delta in script {
                    if delayNanos > 0 {
                        do { try await Task.sleep(nanoseconds: delayNanos) }
                        catch { break }   // 内部任务被取消：直接收尾
                    }
                    continuation.yield(delta)
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason { self.markCancelled() }
            }
        }
    }
}

/// 本地 TTS Mock：把念出的整句记进 spoken，可配置失败与延时；stopSpeaking 记次数。
@MainActor
final class MockLocalTTS: TTSEngine {
    /// 按顺序念出的句子
    private(set) var spoken: [String] = []
    private(set) var stopSpeakingCount = 0
    /// 置非 nil 时 speak 抛出该错误
    var errorToThrow: Error?
    /// 每句合成延时（纳秒）。打断测试用它拉开 speaking 窗口，
    /// 否则瞬时 mock 会在 partial 到达前就跑完整回合。
    var speakDelayNs: UInt64?
    var onSpeak: (() -> Void)?
    var speakHook: (() async -> Void)?

    func speak(_ text: String, onStart: (@Sendable () -> Void)?) async throws {
        if let error = errorToThrow { throw error }
        spoken.append(text)          // 先登记：出声即算"念过"（打断后仍应计数）
        onSpeak?()
        await speakHook?()
        try Task.checkCancellation()
        onStart?()                   // 模拟「首声」回调
        if let delay = speakDelayNs {
            // 延时模拟念完的过程；期间被打断 → 抛取消，但 spoken 已计数
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { throw CancellationError() }
        }
    }

    func stopSpeaking() { stopSpeakingCount += 1 }
}

/// 云端流式 TTS Mock：可配置成功（yield 几片假 PCM）或整句直接抛错；
/// 记录被请求合成的文本。synthesize 抛的是普通 Error（非 CancellationError），
/// 这样才会走 VM 的降级分支而不是打断分支。
final class MockCloudTTS: TTSStreamingEngine, @unchecked Sendable {
    let name = "Mock 云端 TTS"
    private let shouldFail: Bool
    /// 每片之间的延时（纳秒）。打断测试需要它拉开 speaking 窗口，
    /// 否则瞬时 mock 会在 partial 到达前就把整回合跑完。
    private let chunkDelayNs: UInt64?
    private let lock = NSLock()
    private var requestedTexts: [String] = []
    private let failAfterPacket: Bool

    init(shouldFail: Bool, chunkDelayNs: UInt64? = nil, failAfterPacket: Bool = false) {
        self.shouldFail = shouldFail
        self.chunkDelayNs = chunkDelayNs
        self.failAfterPacket = failAfterPacket
    }

    /// 被请求合成的句子（按时间序）
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestedTexts
    }

    func synthesize(text: String) -> AsyncThrowingStream<TTSAudioChunk, Error> {
        lock.lock(); requestedTexts.append(text); lock.unlock()
        return AsyncThrowingStream { continuation in
            if self.shouldFail || self.failAfterPacket {
                if self.failAfterPacket { continuation.yield(TTSAudioChunk(pcm: Data(repeating: 0, count: 64))) }
                continuation.finish(throwing: NSError(
                    domain: "MockCloudTTS", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "模拟云端合成失败"]))
                return
            }
            // 成功：吐三片假 PCM（24kHz/16bit 的占位字节，测试不碰真音频）
            for _ in 0..<3 {
                if let delay = self.chunkDelayNs {
                    Task {
                        try? await Task.sleep(nanoseconds: delay)
                        if Task.isCancelled { continuation.finish(); return }
                        continuation.yield(TTSAudioChunk(pcm: Data(repeating: 0, count: 64)))
                        continuation.finish()
                    }
                    return
                }
                continuation.yield(TTSAudioChunk(pcm: Data(repeating: 0, count: 64)))
            }
            continuation.finish()
        }
    }
}

/// 播放器 Mock：记录播过的 PCM 分片（字节数）与 stopAll 标志；awaitDrained 立即返回。
final class MockPlayer: CallAudioPlayer {
    /// 每片音频的字节数（按入队顺序）
    private(set) var played: [Int] = []
    /// 是否被 stopAll 清过（打断/挂断时置 true）
    private(set) var stopped = false
    var onFirstAudio: (@Sendable () -> Void)?
    var pending = 0
    var onPlay: (() -> Void)?
    var drainHook: (() async -> Void)?

    @MainActor
    func play(pcm: Data) async throws {
        played.append(pcm.count)
        pending += 1
        onPlay?()
        onFirstAudio?()
    }

    @MainActor
    func stopAll() async { stopped = true; pending = 0 }

    @MainActor
    func awaitDrained() async {
        await drainHook?()
        pending = 0
    }
}

/// 语音识别会话 Mock：持有 onEvent，测试用 emitPartial / emitFinal 直接驱动 VM。
@MainActor
final class MockSpeechSession: SpeechSession {
    var onEvent: (@MainActor (STTEvent) -> Void)?
    private(set) var startedCount = 0
    private(set) var stoppedCount = 0
    var startHook: (() async -> Void)?

    func start() async throws { startedCount += 1; await startHook?() }
    func stop() async { stoppedCount += 1 }

    /// 模拟 STT 的临时字幕（speaking 期间用于触发打断）
    func emitPartial(_ text: String) { onEvent?(.partial(text)) }
    /// 模拟一句说完，直接驱动 VM 开跑一轮
    func emitFinal(_ text: String) { onEvent?(.final(text)) }
}

@MainActor
private final class CallTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

// MARK: - 测试

final class CallTests: XCTestCase {

    // MARK: 构造与等待辅助

    /// 组装全 Mock 的 VM：权限与音频会话两个闭包给空实现，绝不碰真权限/真音频
    @MainActor
    private func makeVM(llm: MockLLMClient,
                        localTTS: MockLocalTTS,
                        cloudTTS: MockCloudTTS?,
                        player: MockPlayer,
                        speechSession: MockSpeechSession,
                        route: TTSRoute) -> CallViewModel {
        let vm = CallViewModel(llm: llm, localTTS: localTTS, cloudTTS: cloudTTS,
                               player: player, speechSession: speechSession, route: route,
                               recordMetrics: { _ in })
        vm.requestPermissions = { nil }   // 模拟麦克风权限已授予
        vm.configureAudioSession = {}     // 模拟音频会话配置成功
        vm.deactivateAudioSession = {}    // 不修改宿主音频会话
        return vm
    }

    /// 轮询等待 VM 进入指定状态：每 50ms 检查一次，默认 3 秒超时
    @MainActor
    private func waitPhase(_ expected: CallPhase, of vm: CallViewModel, message: String,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.phase != expected {
            guard Date() < deadline else {
                XCTFail("\(message)（等待 \(expected) 超时，当前仍是 \(vm.phase)）",
                        file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 轮询等待任意条件成立：每 50ms 检查一次，默认 3 秒超时
    @MainActor
    private func waitUntil(_ message: String, timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("\(message)（等待 \(Int(timeout)) 秒超时）", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: a) 分句：增量拼接 + 小数点不切句 + flush 尾巴

    @MainActor
    func testSentenceSplitterSplitAndDecimalNotSplit() async throws {
        var splitter = SentenceSplitter()
        // 两次喂入验证增量：句号处切句；3.14 的点号两侧都是数字，不当句号
        XCTAssertEqual(splitter.feed("你好。3.14"), ["你好。"],
                       "第一段应在句号处切出「你好。」，且 3.14 的小数点不切句")
        XCTAssertEqual(splitter.feed("是多少？"), ["3.14是多少？"],
                       "第二段应与缓冲里的「3.14」拼成完整问句")
        XCTAssertNil(splitter.flush(), "全部内容已切完时 flush 不应再有尾巴")

        // flush 清尾巴：没凑满一句的内容在流结束时必须交出来
        var tailSplitter = SentenceSplitter()
        XCTAssertTrue(tailSplitter.feed("这话还没说完").isEmpty,
                      "没有句末标点时不应产出句子")
        XCTAssertEqual(tailSplitter.flush(), "这话还没说完",
                       "flush 应把没凑满一句的尾巴交出来")
        XCTAssertNil(tailSplitter.flush(), "尾巴交出后再次 flush 应为空")
    }

    // MARK: b) autoFallback：云端失败无感降级本地

    @MainActor
    func testAutoFallbackDegradesToLocal() async throws {
        let llm = MockLLMClient(script: ["你好。"])
        let localTTS = MockLocalTTS()
        let cloud = MockCloudTTS(shouldFail: true)
        let player = MockPlayer()
        let session = MockSpeechSession()
        let vm = makeVM(llm: llm, localTTS: localTTS, cloudTTS: cloud,
                        player: player, speechSession: session, route: .autoFallback)

        vm.startCall()
        await waitPhase(.listening, of: vm, message: "startCall 后应进入收音状态")

        session.emitFinal("你好")
        // 一轮跑完的判定：lastMetrics 已记录（runTurn 末尾会置回 .listening）
        await waitUntil("一轮对话应正常结束（lastMetrics 已记录）") { vm.lastMetrics != nil }
        await waitPhase(.listening, of: vm, message: "一轮结束后应回到收音状态")

        XCTAssertFalse(localTTS.spoken.isEmpty, "云端失败后应降级到本地语音把话说出来")
        XCTAssertEqual(localTTS.spoken.first, "你好。", "本地 TTS 应念出完整句子")
        XCTAssertEqual(cloud.requests, ["你好。"], "云端应先收到整句合成请求再失败")
        XCTAssertFalse(player.stopped, "无感降级不是打断，播放器不应被清空")
        XCTAssertEqual(vm.lastMetrics?.degraded, true, "埋点应记录本次降级")
        XCTAssertNotNil(vm.degradationNote, "降级后应给用户提示")
        XCTAssertEqual(vm.lastMetrics?.actualPath, "local-fallback", "实际路径应记为 local-fallback")
    }

    // MARK: c) deepSeek 显式路由：云端失败同样降级出声并带提示

    @MainActor
    func testDeepSeekRouteAlsoDegradesWithNote() async throws {
        let llm = MockLLMClient(script: ["你好。"])
        let localTTS = MockLocalTTS()
        let cloud = MockCloudTTS(shouldFail: true)
        let player = MockPlayer()
        let session = MockSpeechSession()
        let vm = makeVM(llm: llm, localTTS: localTTS, cloudTTS: cloud,
                        player: player, speechSession: session, route: .deepSeek)

        vm.startCall()
        await waitPhase(.listening, of: vm, message: "startCall 后应进入收音状态")

        session.emitFinal("你好")
        await waitUntil("一轮对话应正常结束（lastMetrics 已记录）") { vm.lastMetrics != nil }
        await waitPhase(.listening, of: vm, message: "一轮结束后应回到收音状态")

        XCTAssertFalse(localTTS.spoken.isEmpty, "显式 deepSeek 路由云端失败时也必须降级出声")
        XCTAssertEqual(localTTS.spoken.first, "你好。", "降级后本地 TTS 应念出完整句子")
        XCTAssertEqual(cloud.requests, ["你好。"], "云端应先收到整句合成请求再失败")
        XCTAssertEqual(vm.lastMetrics?.degraded, true, "显式路由的降级也应记入埋点")
        XCTAssertNotNil(vm.degradationNote, "显式路由降级同样要有提示")
    }

    // MARK: d) local 路由：绝不触碰云端

    @MainActor
    func testLocalRouteNeverTouchesCloud() async throws {
        let llm = MockLLMClient(script: ["你好。"])
        let localTTS = MockLocalTTS()
        // 故意给一个「云端是好的」的 Mock：local 路由连试都不该试
        let cloud = MockCloudTTS(shouldFail: false)
        let player = MockPlayer()
        let session = MockSpeechSession()
        let vm = makeVM(llm: llm, localTTS: localTTS, cloudTTS: cloud,
                        player: player, speechSession: session, route: .local)

        vm.startCall()
        await waitPhase(.listening, of: vm, message: "startCall 后应进入收音状态")

        session.emitFinal("你好")
        await waitUntil("一轮对话应正常结束（lastMetrics 已记录）") { vm.lastMetrics != nil }
        await waitPhase(.listening, of: vm, message: "一轮结束后应回到收音状态")

        XCTAssertTrue(cloud.requests.isEmpty, "local 路由不应向云端发起任何合成请求")
        XCTAssertEqual(localTTS.spoken, ["你好。"], "local 路由应完全走本地语音")
        XCTAssertEqual(vm.lastMetrics?.actualPath, "local", "实际路径应记为 local")
        XCTAssertNil(vm.degradationNote, "local 路由正常工作不应出现降级提示")
    }

    // MARK: e) barge-in：speaking 期间开口打断

    @MainActor
    func testBargeInCancelsLLMAndStopsPlayer() async throws {
        // 慢速流（每增量间隔 100ms）：前 5 个增量不带句号维持思考，
        // 第 6 个以句号收尾触发首句进入 speaking，之后还有一串不带句号的
        // 增量拖住回合，保证 emitPartial 到达时 VM 仍在 speaking 中
        let script = ["今天天气", "真的非常不错", "我们可以", "一起出去走走", "看看这个世界",
                      "。", "然后我们", "还可以聊聊天", "说说别的", "什么话题", "都行呀",
                      "我一直", "在这里", "陪着你", "不着急"]
        let llm = MockLLMClient(script: script, delayMsPerDelta: 100)
        let localTTS = MockLocalTTS()
        localTTS.speakDelayNs = 300_000_000   // 拉开 speaking 窗口，partial 才赶得上打断
        let cloud = MockCloudTTS(shouldFail: false)
        let player = MockPlayer()
        let session = MockSpeechSession()
        let vm = makeVM(llm: llm, localTTS: localTTS, cloudTTS: cloud,
                        player: player, speechSession: session, route: .local)

        vm.startCall()
        await waitPhase(.listening, of: vm, message: "startCall 后应进入收音状态")

        session.emitFinal("你好")
        await waitPhase(.speaking, of: vm, message: "首句开始合成时应进入 speaking")

        // 基线是用户说完那句话的长度（"你好" = 2 字），partial 比基线长 2+ 字
        session.emitPartial("你好我想插句话")

        // interruptNow 全程同步：partial 回调返回时已完成 interrupted → listening
        XCTAssertEqual(vm.phase, .listening, "开口打断后应立即回到收音状态（经 interrupted）")
        await waitUntil("打断应取消 LLM 流") { llm.cancelled }
        await waitUntil("打断应清空播放器") { player.stopped }
        await waitUntil("打断应记入埋点（lastMetrics.interrupted）") { vm.lastMetrics?.interrupted == true }

        XCTAssertEqual(vm.lastMetrics?.interrupted, true, "埋点应标记本轮被打断")
        XCTAssertEqual(localTTS.spoken.count, 1, "打断后不应继续念后续句子")
    }

    @MainActor
    func testHangupDuringPermissionRequestCannotRestartCall() async {
        let session = MockSpeechSession()
        let vm = makeVM(llm: MockLLMClient(script: []), localTTS: MockLocalTTS(), cloudTTS: nil,
                        player: MockPlayer(), speechSession: session, route: .local)
        let gate = CallTestGate()
        var configured = 0
        var cleaned = false
        vm.requestPermissions = { await gate.wait(); return nil }
        vm.configureAudioSession = { configured += 1 }
        vm.deactivateAudioSession = { cleaned = true }
        vm.startCall()
        await waitUntil("权限请求已挂起") { gate.entered }
        vm.shutdown()
        gate.open()
        await waitUntil("挂断清理完成") { cleaned }
        session.emitPartial("迟到字幕")
        session.emitFinal("迟到结果")
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.liveTranscript, "")
        XCTAssertEqual(configured, 0)
        XCTAssertEqual(session.startedCount, 0)
    }

    @MainActor
    func testHangupDuringSpeechStartCannotReturnToListening() async {
        let session = MockSpeechSession()
        let gate = CallTestGate()
        session.startHook = { await gate.wait() }
        let vm = makeVM(llm: MockLLMClient(script: []), localTTS: MockLocalTTS(), cloudTTS: nil,
                        player: MockPlayer(), speechSession: session, route: .local)
        var cleaned = false
        vm.deactivateAudioSession = { cleaned = true }
        vm.startCall()
        await waitUntil("识别启动已挂起") { gate.entered }
        vm.shutdown()
        gate.open()
        await waitUntil("启动取消后完成清理") { cleaned }
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(session.stoppedCount, 1)
    }

    @MainActor
    func testDuplicateFinalInSameTickStartsOnlyOneTurn() async {
        let session = MockSpeechSession()
        let local = MockLocalTTS()
        let vm = makeVM(llm: MockLLMClient(script: ["答复。"]), localTTS: local, cloudTTS: nil,
                        player: MockPlayer(), speechSession: session, route: .local)
        vm.startCall()
        await waitPhase(.listening, of: vm, message: "启动")
        session.emitFinal("第一句")
        XCTAssertEqual(vm.phase, .thinking)
        session.emitFinal("重复句尾")
        await waitUntil("完成一轮") { vm.lastMetrics != nil }
        XCTAssertEqual(local.spoken, ["答复。"])
        XCTAssertEqual(vm.lastMetrics?.userText, "第一句")
        vm.shutdown()
    }

    @MainActor
    func testRapidRedialWaitsForOldTurnAndIgnoresItsState() async {
        let session = MockSpeechSession()
        let local = MockLocalTTS()
        let gate = CallTestGate()
        local.speakHook = { await gate.wait() }
        let vm = makeVM(llm: MockLLMClient(script: ["旧回复。"]), localTTS: local, cloudTTS: nil,
                        player: MockPlayer(), speechSession: session, route: .local)
        vm.startCall()
        await waitPhase(.listening, of: vm, message: "启动")
        session.emitFinal("第一轮")
        await waitUntil("旧语音挂起") { gate.entered }
        vm.shutdown()
        XCTAssertEqual(vm.phase, .idle)
        vm.startCall()
        XCTAssertEqual(vm.phase, .preparing)
        local.speakHook = nil
        gate.open()
        await waitPhase(.listening, of: vm, message: "清理后重拨")
        XCTAssertEqual(session.startedCount, 2)
        XCTAssertNil(vm.lastMetrics, "旧通话不能发布到新通话UI")
        session.emitFinal("新轮")
        await waitUntil("新轮正常完成") { vm.lastMetrics?.userText == "新轮" }
        XCTAssertFalse(vm.lastMetrics?.interrupted ?? true)
        vm.shutdown()
    }

    @MainActor
    func testCloudFailureAfterPacketStopsResidualBeforeLocalFallback() async {
        let session = MockSpeechSession()
        let local = MockLocalTTS()
        let player = MockPlayer()
        local.onSpeak = { XCTAssertEqual(player.pending, 0, "降级前必须清理云端残音") }
        let vm = makeVM(llm: MockLLMClient(script: ["你好。"]), localTTS: local,
                        cloudTTS: MockCloudTTS(shouldFail: false, failAfterPacket: true),
                        player: player, speechSession: session, route: .autoFallback)
        vm.startCall()
        await waitPhase(.listening, of: vm, message: "启动")
        session.emitFinal("你好")
        await waitUntil("降级完成") { vm.lastMetrics != nil }
        XCTAssertEqual(player.played.count, 1)
        XCTAssertTrue(player.stopped)
        XCTAssertEqual(local.spoken, ["你好。"])
        XCTAssertEqual(vm.lastMetrics?.degraded, true)
        vm.shutdown()
    }

    @MainActor
    func testCloudToLocalRouteWaitsForQueuedAudio() async {
        let session = MockSpeechSession()
        let local = MockLocalTTS()
        let player = MockPlayer()
        let gate = CallTestGate()
        let vm = makeVM(llm: MockLLMClient(script: ["第一句。第二句。"]), localTTS: local,
                        cloudTTS: MockCloudTTS(shouldFail: false), player: player,
                        speechSession: session, route: .autoFallback)
        let savedRoute = TTSRoute.saved
        defer { TTSRoute.saved = savedRoute }
        player.onPlay = { vm.updateRoute(.local) }
        player.drainHook = { await gate.wait() }
        vm.startCall()
        await waitPhase(.listening, of: vm, message: "启动")
        session.emitFinal("你好")
        await waitUntil("正在等待云端队列") { gate.entered }
        XCTAssertTrue(local.spoken.isEmpty)
        player.drainHook = nil
        player.onPlay = nil
        gate.open()
        await waitUntil("本地句播放结束") { vm.lastMetrics != nil }
        XCTAssertEqual(local.spoken, ["第二句。"])
        vm.shutdown()
    }

    @MainActor
    func testLocalSpeechFailureRemainsErrorAndStopsSession() async {
        let session = MockSpeechSession()
        let local = MockLocalTTS()
        local.errorToThrow = ToolLoopError(message: "test failure")
        let vm = makeVM(llm: MockLLMClient(script: ["你好。"]), localTTS: local, cloudTTS: nil,
                        player: MockPlayer(), speechSession: session, route: .local)
        var cleaned = false
        vm.deactivateAudioSession = { cleaned = true }
        vm.startCall()
        await waitPhase(.listening, of: vm, message: "启动")
        session.emitFinal("你好")
        await waitUntil("错误路径也要释放资源") { cleaned }
        guard case .error(let message) = vm.phase else { return XCTFail("不能被轮次收尾覆盖为listening") }
        XCTAssertTrue(message.contains("test failure"))
        XCTAssertEqual(session.stoppedCount, 1)
    }

    // MARK: f) TTS 端点归一化

    @MainActor
    func testTTSURLNormalization() throws {
        XCTAssertEqual(
            DeepSeekTTSStreamingEngine.ttsURL(fromBase: "https://api.deepseek.com/v1")?.absoluteString,
            "https://api.deepseek.com/v1/tools/tts",
            "带 /v1 的 baseURL 应直接拼接 tools/tts")
        XCTAssertEqual(
            DeepSeekTTSStreamingEngine.ttsURL(fromBase: "https://api.deepseek.com")?.absoluteString,
            "https://api.deepseek.com/v1/tools/tts",
            "不带 /v1 的 baseURL 应自动补 /v1/tools/tts")
        XCTAssertEqual(
            DeepSeekTTSStreamingEngine.ttsURL(fromBase: "https://proxy.example.com/x")?.absoluteString,
            "https://proxy.example.com/x/v1/tools/tts",
            "带路径前缀的 baseURL 应保留前缀再拼接")
        XCTAssertEqual(
            DeepSeekTTSStreamingEngine.ttsURL(fromBase: "https://api.deepseek.com/v1/")?.absoluteString,
            "https://api.deepseek.com/v1/tools/tts",
            "结尾斜杠应被归一化后再拼接")
        XCTAssertNil(DeepSeekTTSStreamingEngine.ttsURL(fromBase: "not-a-url"),
                     "解析不出 host 的 baseURL 应返回 nil")
    }

    // MARK: g) Keychain 往返

    @MainActor
    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "local.fenshen.tests")
        let account = "apiKey"
        store.remove(account: account)   // 先清场，保证从干净状态开始
        addTeardownBlock { store.remove(account: account) }

        do {
            try store.set("sk-test-12345", account: account)
            XCTAssertEqual(store.string(account: account), "sk-test-12345",
                           "Keychain 写入后应能原样读出")
            try store.set("sk-updated-67890", account: account)   // 第二次走更新路径
        } catch {
            // 模拟器/CI 测试环境可能禁写 Keychain：跳过而不是失败
            throw XCTSkip("Keychain 在测试环境写入失败（status \((error as NSError).code)），跳过往返验证")
        }

        XCTAssertEqual(store.string(account: account), "sk-updated-67890",
                       "Keychain 更新后应读到最新值")
        store.remove(account: account)
        XCTAssertNil(store.string(account: account), "Keychain 删除后应读不到")
    }
}
