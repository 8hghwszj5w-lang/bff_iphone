import Foundation

// MARK: - LLM 客户端：把现有 Pipeline（人设+记忆+工具）适配成流式协议
//
// 通话与打字共享同一个"大脑"：Pipeline.handle 内部就是
// 记忆 → DeepSeek 流式（含 web_search 工具循环）→ 清洗 → 落盘。
// 这里只是把它的 onDelta 回调桥接成 AsyncThrowingStream，
// 让 CallViewModel 用 for await 消费，取消 Task 即取消网络流。

struct PipelineLLMClient: LLMClient {
    /// Pipeline 是 MainActor 隔离的，持有引用即可（调用点也在 MainActor 上下文）
    nonisolated(unsafe) private unowned let pipeline: Pipeline

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
    }

    func streamReply(userText: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    // 文本增量逐段 yield；handle 返回时流自然结束
                    let final = try await pipeline.handle(userText: userText) { delta in
                        continuation.yield(delta)
                    }
                    _ = final
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 下游（CallViewModel 打断/退出）取消流 → 取消 handle 内部任务 → 断网
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }
}
