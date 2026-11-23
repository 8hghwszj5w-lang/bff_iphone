import XCTest
import Foundation
import AVFoundation
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

        // 句段级 partial（SpeechTranscriber 每句段重发 volatile 文本）：
        // speaking 期间出现非空 partial 即视为用户又开口 → 打断
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

    /// 连续多轮：第一轮正常结束后，第二句（SpeechTranscriber 的下一段 final）
    /// 必须能开新一轮——旧实现按累计文本做前缀差分，第二段比累计值短会被丢掉，
    /// 表现为「多轮对话不可用」。这里锁死 VM 侧的多轮生命周期。
    @MainActor
    func testConsecutiveTurnsKeepConversationAlive() async throws {
        let session = MockSpeechSession()
        let local = MockLocalTTS()
        let vm = makeVM(llm: MockLLMClient(script: ["答复。"]), localTTS: local, cloudTTS: nil,
                        player: MockPlayer(), speechSession: session, route: .local)
        vm.startCall()
        await waitPhase(.listening, of: vm, message: "启动")
        session.emitFinal("第一句")
        await waitUntil("第一轮完成") { vm.lastMetrics?.userText == "第一句" }
        await waitPhase(.listening, of: vm, message: "第一轮结束应回到收音")
        session.emitFinal("第二句话")
        await waitUntil("第二轮完成") { vm.lastMetrics?.userText == "第二句话" }
        XCTAssertEqual(vm.phase, .listening)
        XCTAssertEqual(local.spoken, ["答复。", "答复。"], "两轮都应正常合成")
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

// MARK: - SentenceSplitter 增量扫描等价性（性能优化不改变切句行为）
//
// 优化后只扫描新到字符。用旧算法（全量重扫）做参照，对各种分片粒度逐一对比，
// 证明包括「末尾点号立即切句」「小数点不切」等边界行为完全一致。
private struct ReferenceSentenceSplitter {
    private var buffer = ""
    private let terminators: Set<Character> = ["。", "！", "？", "；", "…", "\n", "!", "?", ";"]

    mutating func feed(_ delta: String) -> [String] {
        buffer += delta
        let chars = Array(buffer)
        var sentences: [String] = []
        var sentenceStart = 0
        for i in 0..<chars.count {
            let ch = chars[i]
            let isSentenceEnd = terminators.contains(ch)
                || (ch == "." && !(i > 0 && chars[i - 1].isNumber
                                   && i + 1 < chars.count && chars[i + 1].isNumber))
            if isSentenceEnd {
                let sentence = String(chars[sentenceStart...i])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                sentenceStart = i + 1
            }
        }
        buffer = sentenceStart < chars.count ? String(chars[sentenceStart...]) : ""
        return sentences
    }

    mutating func flush() -> String? {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return tail.isEmpty ? nil : tail
    }
}

final class SentenceSplitterEquivalenceTests: XCTestCase {
    func testIncrementalScanMatchesReferenceAcrossChunkSizes() {
        let corpus = [
            "你好。3.14是多少？OK! 2.5x3.2=8.0 done.\n再见…",
            "没有标点的一整段很长很长的中文内容看看会不会切出句子来",
            "。。。！？；…\n\n!!!???;;;",
            "价格是3.14元，版本2.0.1发布了。结尾是点号.",
            "   。  \n  你好  。  ",
            "混合English.中文。数字123.456结束!尾巴",
            "",
            "。",
            "a.b.c.d",
        ]
        for text in corpus {
            for chunkSize in [1, 2, 3, 5, 7, 64] {
                var actual = SentenceSplitter()
                var reference = ReferenceSentenceSplitter()
                var actualSentences: [String] = []
                var referenceSentences: [String] = []
                var index = text.startIndex
                while index < text.endIndex {
                    let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                    let piece = String(text[index..<end])
                    actualSentences += actual.feed(piece)
                    referenceSentences += reference.feed(piece)
                    index = end
                }
                XCTAssertEqual(actualSentences, referenceSentences,
                               "分片粒度 \(chunkSize) 下切句结果必须与旧算法一致：\(text.debugDescription)")
                XCTAssertEqual(actual.flush(), reference.flush(),
                               "分片粒度 \(chunkSize) 下 flush 尾巴必须一致：\(text.debugDescription)")
            }
            // 整段一次喂入也要一致
            var whole = SentenceSplitter()
            var wholeRef = ReferenceSentenceSplitter()
            XCTAssertEqual(whole.feed(text), wholeRef.feed(text))
            XCTAssertEqual(whole.flush(), wholeRef.flush())
        }
    }
}

// MARK: - DeepSeek TTS 流式（delegate 分块直出）离线测试
//
// 全部走 URLProtocol 桩，不调真实接口。重点验证：
// ① 奇数字节分片的 16bit 采样对齐（错位半字节 = 播放全是噪声）
// ② 首包阈值（1024）与后续批量（4096）
// ③ Content-Length 断流视为失败（文档要求）
// ④ HTTP 错误码透传

/// TTS 离线桩：按预设分片序列投递响应体（可配 Content-Length 制造断流）。
/// chunkDelay > 0 时在后台线程逐片异步投递——同步连投会被 URLSession 合并成
/// 一次 didReceive data，测不出「分片到达即处理」的真实行为。
final class TTSStubProtocol: URLProtocol {
    struct StubResponse {
        var status: Int = 200
        var chunks: [Data] = []
        var contentLength: Int64?
        var chunkDelay: TimeInterval = 0
    }
    static var stub: StubResponse?

    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if let length = stub.contentLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if stub.chunkDelay > 0 {
            let chunks = stub.chunks
            let delay = stub.chunkDelay
            Thread.detachNewThread { [self] in
                for chunk in chunks {
                    if self.isStopped { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                    Thread.sleep(forTimeInterval: delay)
                }
                if !self.isStopped { self.client?.urlProtocolDidFinishLoading(self) }
            }
        } else {
            for chunk in stub.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

final class DeepSeekTTSStreamingTests: XCTestCase {
    private var engine: DeepSeekTTSStreamingEngine!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSStubProtocol.self]
        engine = DeepSeekTTSStreamingEngine(config: .init(
            apiKey: "sk-test",
            ttsURL: URL(string: "https://stub.local/v1/tools/tts")!,
            session: URLSession(configuration: configuration)))
    }

    override func tearDown() {
        TTSStubProtocol.stub = nil
        engine = nil
        super.tearDown()
    }

    private func collect() async throws -> (Data, [Int]) {
        var received = Data()
        var sizes: [Int] = []
        for try await chunk in engine.synthesize(text: "你好") {
            received.append(chunk.pcm)
            sizes.append(chunk.pcm.count)
        }
        return (received, sizes)
    }

    func testOddChunkSplitsAreSampleAligned() async throws {
        // 6000 字节音频，故意用奇数分片逐片异步投递（网络常态），验证半字节拼接不错位。
        // 分片 [1,3,5,7,1023,2049,2912]：前 5 片累计 1039 字节，对齐后进位 1038 ≥ 1024
        // → 首包应为 1038 字节（而不是等全部 6000 攒齐）；其余按 4096 阈值批量。
        let original = Data((0..<6000).map { UInt8($0 % 251) })
        var chunks: [Data] = []
        var offset = 0
        for size in [1, 3, 5, 7, 1023, 2049] {
            chunks.append(original.subdata(in: offset..<(offset + size)))
            offset += size
        }
        chunks.append(original.subdata(in: offset..<original.count))
        TTSStubProtocol.stub = .init(chunks: chunks, contentLength: Int64(original.count),
                                     chunkDelay: 0.02)

        let (received, sizes) = try await collect()
        XCTAssertEqual(received, original, "奇数分片必须按 16bit 采样对齐重组，字节序不能错位")
        XCTAssertTrue(sizes.allSatisfy { $0 % 2 == 0 }, "每个分片都应是完整采样（偶数字节）")
        XCTAssertEqual(sizes.first, 1038, "首包应在跨过 1024 阈值的那一片到达时立即产出")
        XCTAssertLessThan(sizes.first ?? .max, original.count, "首包不应等到全部音频攒齐")
    }

    func testSmallResponseYieldsRemainderOnFinish() async throws {
        let original = Data(repeating: 0x7F, count: 500)   // 不足首包阈值
        TTSStubProtocol.stub = .init(chunks: [original], contentLength: 500)
        let (received, sizes) = try await collect()
        XCTAssertEqual(received, original)
        XCTAssertEqual(sizes, [500], "不足阈值的音频应在流结束时整体交出")
    }

    func testTruncatedStreamFails() async throws {
        // Content-Length 声称 10000 字节，实际只投 4000 → 必须报错而不是静默成功
        let partial = Data(repeating: 0x01, count: 4000)
        TTSStubProtocol.stub = .init(chunks: [partial], contentLength: 10_000)
        do {
            _ = try await collect()
            XCTFail("断流必须视为失败（文档要求），不能静默结束")
        } catch {
            // URLProtocol 桩下可能由 URLSession 先报网络错误，也可能是本端 -2 校验；
            // 两者都满足「断流 = 失败」的契约。若是本端错误则校验错误码。
            let ns = error as NSError
            if ns.domain == "DeepSeekTTS" {
                XCTAssertEqual(ns.code, -2, "本端断流校验应使用错误码 -2")
            }
        }
    }

    func testHTTPErrorIsPropagated() async throws {
        TTSStubProtocol.stub = .init(status: 429, chunks: [], contentLength: 0)
        do {
            _ = try await collect()
            XCTFail("HTTP 429 必须抛错")
        } catch {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "DeepSeekTTS")
            XCTAssertEqual(ns.code, 429, "HTTP 状态码应透传为错误码（供降级/冷却逻辑使用）")
        }
    }

    func testSequentialRequestsReuseEngine() async throws {
        // 同一引擎连续两句（通话常态）：连接池复用，状态表不串流
        let first = Data(repeating: 0x11, count: 2048)
        TTSStubProtocol.stub = .init(chunks: [first], contentLength: Int64(first.count))
        let (r1, _) = try await collect()
        XCTAssertEqual(r1, first)

        let second = Data(repeating: 0x22, count: 8192)
        TTSStubProtocol.stub = .init(chunks: [second], contentLength: Int64(second.count))
        let (r2, sizes2) = try await collect()
        XCTAssertEqual(r2, second, "第二句不能混入第一句的残留字节")
        XCTAssertTrue(sizes2.allSatisfy { $0 % 2 == 0 })
    }
}

// MARK: - 播放图格式约束（真实引擎验证）
//
// 两个在模拟器上已验证的硬约束：
// ① AVAudioPlayerNode 不做位深/采样率转换——调度 buffer 必须与节点连接格式一致，
//    否则 int16 字节被按 float32 解释（离线渲染测试抓到 10^38 级垃圾值 = 真机杂音）；
// ② mixer 输入总线不接受 int16（连接时 kAudioUnitErr_FormatNotSupported -10868）。
// 因此生产实现：play() 把 int16 PCM 转 float32，节点按 float32@24kHz 连接，
// 采样率转换由 mixer 完成。本测试验证该配置下真实引擎能播完 0.2s 音频。
final class StreamingAudioGraphFormatTests: XCTestCase {
    func testPlayerNodePlaysFloat32_24kBufferOnMatchingGraph() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graphFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        engine.connect(player, to: engine.mainMixerNode, format: graphFormat)

        let frames: AVAudioFrameCount = 4_800   // 0.2s @ 24kHz
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: graphFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let phase = 2.0 * Double.pi * 440.0 * Double(i) / 24_000.0
            buffer.floatChannelData?[0][i] = Float(0.12 * sin(phase))
        }

        engine.prepare()
        try engine.start()
        defer { player.stop(); engine.stop() }

        let played = expectation(description: "float32 @24kHz buffer 应在匹配图上播完")
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            played.fulfill()
        }
        player.play()
        wait(for: [played], timeout: 5)
    }
}

// MARK: - 播放管线样本级验证（离线渲染 + int16→float32 转换）
//
// 「云端测试音频播放杂音」的回归：真实图（AVAudioPlayerNode → mixer → 48kHz
// 输出）离线渲染 0.5s 440Hz 正弦，抓输出样本验证是幅度/频率正确的正弦而不是
// 噪声；另有 play() 的 int16→float32 转换单元测试。改动图格式或数据转换方式
// 时这里会直接失败。

final class PlaybackGraphRenderingTests: XCTestCase {
    func testFloat32_24kSineRendersCleanlyOn48kOutput() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graphFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        engine.connect(player, to: engine.mainMixerNode, format: graphFormat)
        let renderFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)

        let inputFrames: AVAudioFrameCount = 12_000
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: graphFormat, frameCapacity: inputFrames))
        input.frameLength = inputFrames
        for i in 0..<Int(inputFrames) {
            let phase = 2.0 * Double.pi * 440.0 * Double(i) / 24_000.0
            input.floatChannelData?[0][i] = Float(0.488 * sin(phase))
        }

        try engine.start()
        player.scheduleBuffer(input, completionCallbackType: .dataPlayedBack, completionHandler: nil)
        player.play()

        let renderBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: 4096))
        var samples: [Float] = []
        var remaining = 26_400
        while remaining > 0 {
            let frames = min(4096, remaining)
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: renderBuffer)
            XCTAssertEqual(status, .success)
            guard let data = renderBuffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: (0..<Int(renderBuffer.frameLength)).map { data[$0] })
            remaining -= Int(renderBuffer.frameLength)
        }
        try engine.stop()

        XCTAssertGreaterThan(samples.count, 24_000)
        let analysis = Array(samples[2_400..<24_000])
        let peak = analysis.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.3, "输出必须有信号（输入幅度≈0.49），不能是静音")
        XCTAssertLessThan(peak, 0.9, "输出不应失真削波")
        var crossings = 0
        for i in 1..<analysis.count where analysis[i - 1] <= 0 && analysis[i] > 0 {
            crossings += 1
        }
        XCTAssertTrue((180...220).contains(crossings),
                      "输出应为 440Hz 正弦（零交叉≈198），实际 \(crossings) —— 超出范围说明转换出错（杂音）")
    }
}

// MARK: - play() 的 int16 → float32 转换（不创建真实引擎）

/// 捕获调度 buffer 的桩：验证 play() 把 24k/int16 PCM 正确转成 float32 入队。
private final class CapturingAudioOutput: StreamingAudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    var captured: [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }

    func schedule(_ buffer: AVAudioPCMBuffer,
                  completion: @escaping @Sendable () async -> Void) throws {
        lock.lock(); buffers.append(buffer); lock.unlock()
        Task { await completion() }
    }

    func stop() {}
    func shutdown() {}
}

final class PlaybackPCMConversionTests: XCTestCase {
    func testPlayConvertsInt16ToFloat32At24k() async throws {
        let output = CapturingAudioOutput()
        let player = StreamingAudioPlayer(output: output)
        // 4 个采样：0, 16384, -16384, 32767（小端 int16）
        let samples: [Int16] = [0, 16_384, -16_384, 32_767]
        var data = Data()
        for s in samples {
            data.append(contentsOf: withUnsafeBytes(of: s.littleEndian) { Array($0) })
        }

        try await player.play(pcm: data)
        let buffer = try XCTUnwrap(output.captured.first)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32,
                       "入队 buffer 必须是 float32（int16 会被播放节点/混音器误解释）")
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(buffer.frameLength, 4)
        let converted = (0..<4).map { buffer.floatChannelData?[0][$0] ?? .nan }
        XCTAssertEqual(converted[0], 0, accuracy: 0.0005)
        XCTAssertEqual(converted[1], 0.5, accuracy: 0.0005)
        XCTAssertEqual(converted[2], -0.5, accuracy: 0.0005)
        XCTAssertEqual(converted[3], 0.99997, accuracy: 0.0005)
        await player.stopAll()
    }
}
