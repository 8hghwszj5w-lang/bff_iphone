import AVFoundation
import Foundation

// MARK: - 流式音频播放器（云端 PCM 分片顺序播放）
//
// actor：play() 从任意线程/任务调用都安全。
// 每个 buffer 有独立 token，stop 后迟到/重复的回调不能扣减新一轮的待播内容。
// awaitDrained() 由 dataPlayed / stop / 任务取消唤醒，不轮询、不吞取消后忙等。

/// 仅由拥有它的 StreamingAudioPlayer actor 串行访问；测试无需创建 AVAudioEngine。
protocol StreamingAudioOutput: AnyObject, Sendable {
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () async -> Void) throws
    func stop()
    func shutdown()
}

actor StreamingAudioPlayer: CallAudioPlayer {
    private let output: any StreamingAudioOutput
    /// 播放图格式：float32 @ 24kHz 单声道，与调度 buffer 完全一致。
    /// 两条硬约束（离线渲染/真实图测试已证实）：
    /// ① AVAudioPlayerNode 不做位深/采样率转换——buffer 与节点格式不一致时
    ///    把 int16 字节按 float32 解释，输出 10^38 级垃圾值（真机=杂音）；
    /// ② mixer 输入总线不接受 int16（kAudioUnitErr_FormatNotSupported -10868）。
    /// 所以在 play() 里把 int16 转成 float32 入队；采样率转换交给 mixer。
    private let graphFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var scheduledBuffers = Set<UUID>()
    private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init() {
        output = AVStreamingAudioOutput()
    }

    init(output: any StreamingAudioOutput) {
        self.output = output
    }

    /// 复用通话会话的麦克风引擎：播放节点接入同一 AVAudioEngine。
    /// 双引擎（播放器自建 + voice-processing 麦克风引擎）会争抢同一音频会话的
    /// IO：合成音听不到、dataPlayedBack 不触发（awaitDrained 卡死 → 多轮对话
    /// 不可用）、引擎反复启停爆音。单引擎还让系统回声消除把 TTS 外放计入参考。
    init(sharedEngine: AVAudioEngine) {
        output = AVStreamingAudioOutput(sharedEngine: sharedEngine)
    }

    func play(pcm: Data) async throws {
        try Task.checkCancellation()
        let frames = UInt32(pcm.count / MemoryLayout<Int16>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: graphFormat, frameCapacity: frames),
              let dst = buffer.floatChannelData?[0] else {
            return
        }
        buffer.frameLength = frames
        // int16 (little-endian) → float32，满幅映射到 ±1（对齐 AVAudioConverter 的
        // 32768 缩放；逐字节取值避免 Data 指针未按 2 字节对齐时的未定义行为）。
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<Int(frames) {
                let lo = UInt16(base[i * 2])
                let hi = UInt16(base[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                dst[i] = Float(sample) / 32_768.0
            }
        }

        let id = UUID()
        scheduledBuffers.insert(id)
        do {
            try output.schedule(buffer) { [weak self] in
                Task { await self?.bufferConsumed(id: id) }
            }
        } catch {
            bufferConsumed(id: id)
            throw error
        }
    }

    private func bufferConsumed(id: UUID) {
        guard scheduledBuffers.remove(id) != nil else { return }
        if scheduledBuffers.isEmpty { resumeDrainWaiters() }
    }

    func stopAll() async {
        // 先失效化，再调用 stop（AVAudioPlayerNode.stop 本身也可能发送完成回调）。
        scheduledBuffers.removeAll()
        output.stop()
        resumeDrainWaiters()
    }

    func awaitDrained() async {
        guard !Task.isCancelled, !scheduledBuffers.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !scheduledBuffers.isEmpty else {
                    continuation.resume()
                    return
                }
                drainWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelDrainWaiter(id: id) }
        }
    }

    private func cancelDrainWaiter(id: UUID) {
        // 只取消此调用者的等待，不把其他等待者/仍在播放的音频一起取消。
        drainWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    /// 退出通话：调用者 await 完成本 actor 内清理；音频会话降活跃由 VM 负责。
    /// 声明为 async 以满足 CallAudioPlayer 的非隔离异步要求（同步隔离方法会退回协议默认实现）。
    func shutdown() async {
        scheduledBuffers.removeAll()
        output.shutdown()
        resumeDrainWaiters()
    }
}

/// @unchecked Sendable 的约束由外层 actor 保证：节点/engine 不逃逸，不并发操作。
private final class AVStreamingAudioOutput: StreamingAudioOutput, @unchecked Sendable {
    /// 播放所在引擎。归属规则：
    /// · sharedEngine（通话中）：复用会话的麦克风引擎，本类不负责启停；
    /// · nil（对比页等无通话场景）：自建独立引擎，由本类负责启停。
    private let engine: AVAudioEngine
    private let ownsEngine: Bool
    private let playerNode = AVAudioPlayerNode()
    private var graphConnected = false

    init(sharedEngine: AVAudioEngine? = nil) {
        if let sharedEngine {
            engine = sharedEngine
            ownsEngine = false
        } else {
            engine = AVAudioEngine()
            ownsEngine = true
        }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () async -> Void) throws {
        // 图连接与 engine 是否启动是两种状态；启动失败或 shutdown 后重试不能重复 attach。
        if !graphConnected {
            engine.attach(playerNode)
            // ⚠️ 播放节点必须按 PCM 原始格式连接（24kHz/int16 单声道），
            // 与待播 buffer 完全一致：AVAudioPlayerNode 不做位深/采样率转换
            // （只预检声道数），格式不一致时它把 int16 字节按 float32 解释——
            // 输出是 10^38 级垃圾值，真机上就是「云端测试音频播放杂音」。
            // 采样率转换交给 mixer 逐路完成（mixer 输入总线支持任意 PCM 格式）。
            engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
            graphConnected = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
            #if DEBUG
            print("[Call] 播放引擎已启动")
            #endif
        }
        // 默认 dataConsumed 比真正出声结束早，不能用它判定本轮已播完。
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { await completion() }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    func stop() {
        playerNode.stop()
    }

    func shutdown() {
        // 先停节点（挂起的 dataPlayedBack 会收到完成回调，awaitDrained 不会挂住）；
        // 引擎归还给会话管理，避免本类停掉会话正在使用的引擎。
        playerNode.stop()
        if ownsEngine { engine.stop() }
    }
}
