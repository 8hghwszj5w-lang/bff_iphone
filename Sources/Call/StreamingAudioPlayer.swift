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
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 24_000, channels: 1, interleaved: true)!
    private var scheduledBuffers = Set<UUID>()
    private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init() {
        output = AVStreamingAudioOutput()
    }

    init(output: any StreamingAudioOutput) {
        self.output = output
    }

    func play(pcm: Data) async throws {
        try Task.checkCancellation()
        let frames = UInt32(pcm.count / MemoryLayout<Int16>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                dst.update(from: src.assumingMemoryBound(to: Int16.self), count: Int(frames))
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
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var graphConnected = false

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () async -> Void) throws {
        // 图连接与 engine 是否启动是两种状态；启动失败或 shutdown 后重试不能重复 attach。
        if !graphConnected {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
            graphConnected = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
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
        playerNode.stop()
        engine.stop()
    }
}
