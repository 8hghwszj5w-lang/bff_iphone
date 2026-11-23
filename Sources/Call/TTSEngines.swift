import AVFoundation
import Foundation

// MARK: - 路径 A：本地 TTS（AVSpeechSynthesizer，优先 enhanced/premium 中文音色）
//
// speak() 在整句念完（或取消）后才返回 → CallViewModel 逐句 await 即保证句序。
// 首声（didStart）通过 onStart 回调上报，用于本地路径的"端到端首音"埋点。

enum LocalSpeechEvent {
    case started, finished, cancelled
}

/// 注入边界：测试只发送回调，不创建真实合成器或激活音频会话。
@MainActor
protocol LocalSpeechSynthesizing: AnyObject {
    var onEvent: (@MainActor (LocalSpeechEvent, AVSpeechUtterance) -> Void)? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func stop()
}

@MainActor
final class LocalAVSpeechTTSEngine: TTSEngine {
    private let synthesizer: any LocalSpeechSynthesizing

    private struct PendingSpeech {
        let id: UUID
        let utterance: AVSpeechUtterance
        let continuation: CheckedContinuation<Void, Error>
        var onStart: (@Sendable () -> Void)?
    }
    private var pendingSpeech: PendingSpeech?

    convenience init() {
        self.init(synthesizer: LocalAVSpeechSynthesizer())
    }

    init(synthesizer: any LocalSpeechSynthesizing) {
        self.synthesizer = synthesizer
        synthesizer.onEvent = { [weak self] event, utterance in
            self?.handle(event, utterance: utterance)
        }
    }

    func speak(_ text: String, onStart: (@Sendable () -> Void)?) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.cachedChineseVoice
        // 默认 0.5；通话场景略慢更自然
        utterance.rate = 0.52
        utterance.postUtteranceDelay = 0.15
        utterance.preUtteranceDelay = 0.05

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 取消可发生在注册 handler 之前；不能先入队再等 didCancel。
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // 重入时显式结束旧句，而不是覆盖其续体；没有旧句就不打扰合成器。
                if pendingSpeech != nil { stopSpeaking() }
                pendingSpeech = PendingSpeech(id: id, utterance: utterance,
                                              continuation: continuation, onStart: onStart)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                // 旧任务的取消 handler 可能晚于下一句才执行。
                guard self?.pendingSpeech?.id == id else { return }
                self?.stopSpeaking()
            }
        }
        try Task.checkCancellation()
    }

    func stopSpeaking() {
        let pending = pendingSpeech
        pendingSpeech = nil
        synthesizer.stop()
        // stopSpeaking 不保证一定发 didCancel；先 take + nil，自己可靠结束等待。
        pending?.continuation.resume(throwing: CancellationError())
    }

    private func handle(_ event: LocalSpeechEvent, utterance: AVSpeechUtterance) {
        guard let pending = pendingSpeech, pending.utterance === utterance else { return }
        switch event {
        case .started:
            pendingSpeech?.onStart = nil
            pending.onStart?()
        case .finished, .cancelled:
            pendingSpeech = nil
            if case .cancelled = event {
                pending.continuation.resume(throwing: CancellationError())
            } else {
                pending.continuation.resume()
            }
        }
    }

    /// 音色优先级：premium > enhanced > 默认 zh-CN。
    /// enhanced/premium 需要在 设置 → 辅助功能 → 朗读内容 → 声音 里下载过才有。
    /// nonisolated：speechVoices() 线程安全，且缓存初始化可能发生在任意上下文。
    nonisolated static func preferredChineseVoice() -> AVSpeechSynthesisVoice? {
        let zh = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        return zh.first { $0.quality == .premium }
            ?? zh.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    /// speechVoices() 是全系统音色枚举（真机可达几十毫秒），通话逐句合成不能每句都查。
    /// 首次用时查一次并缓存；会话中途新下载的音色下次启动生效（可接受的取舍）。
    private static let cachedChineseVoice: AVSpeechSynthesisVoice? = preferredChineseVoice()
}

/// 保留 utterance 对象跨主线程投递：旧回调不能被误认作下一句。
@MainActor
private final class LocalAVSpeechSynthesizer: NSObject, LocalSpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onEvent: (@MainActor (LocalSpeechEvent, AVSpeechUtterance) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ utterance: AVSpeechUtterance) {
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.onEvent?(.started, utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.onEvent?(.finished, utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.onEvent?(.cancelled, utterance) }
    }
}

// MARK: - 路径 B：DeepSeek TTS API（HTTP 流式 PCM）
//
// ⚠️ 接口按官方文档实现（api-docs.deepseek.com/zh-cn/guides/tts，2026-11 核对）：
//   POST {root}/v1/tools/tts
//   body: {"text": "...", "voice_id": "stella"|"tide", "format": "pcm", "filter_markdown": true}
//   响应体：音频边合成边返回；pcm = 24kHz / 16bit / 单声道
//   错误：400 无文本或内容审核 / 429 并发超限 / 503 繁忙 / 504 超时
//   注意：音频中途断流视为失败（文档明确要求），实现里校验 Content-Length
// 不支持语速调节与断点续传，因此打断 = 直接取消请求。
//
// 流式实现：URLSessionDataDelegate 分块直出（TTSStreamHub）。
// 此前用 AsyncBytes 逐字节 await + 攒满 4096 才 yield：每秒音频 4.8 万次异步
// 迭代白白烧 CPU，首包还要等 85ms 音频攒够。现在网络分片到达即处理，
// 首包攒够 1024 字节（≈21ms 音频）就交给播放器，后续按 4096 批量，
// 端到端首音更快、通话期间 CPU 占用显著更低。

final class DeepSeekTTSStreamingEngine: TTSStreamingEngine, Sendable {
    let name = "DeepSeek TTS"

    struct Config: Sendable {
        var apiKey: String
        var ttsURL: URL
        var voiceID: String = "stella"      // stella(女声,默认) / tide(男声)
        /// 提供 URLSessionConfiguration（含测试注入的 URLProtocol 桩）；
        /// 实际请求走引擎自建的 delegate 会话（见 TTSStreamHub）。
        var session: URLSession = .shared
    }

    private let config: Config
    private let hub: TTSStreamHub

    init(config: Config) {
        self.config = config
        self.hub = TTSStreamHub(configuration: config.session.configuration)
    }

    deinit {
        // URLSession 强引用 delegate 直到显式 invalidate；引擎随通话页销毁，
        // 不主动失效会泄漏会话（每次进通话页新建一个引擎）。
        hub.close()
    }

    /// 便捷构造：从用户配置的 baseURL 推导。
    /// 官方 TTS 端点是绝对路径 /v1/tools/tts（与 /files 在根路径不同！），
    /// 因此无论 base 带不带 /v1，都先剥掉尾部的 /v1 再拼 /v1/tools/tts，避免双写：
    ///   https://api.deepseek.com/v1  → https://api.deepseek.com/v1/tools/tts
    ///   https://api.deepseek.com     → https://api.deepseek.com/v1/tools/tts
    ///   https://proxy.example.com/x  → https://proxy.example.com/x/v1/tools/tts
    static func ttsURL(fromBase baseURL: String) -> URL? {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard var components = URLComponents(string: value),
              let host = components.host, !host.isEmpty else { return nil }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath.hasSuffix("/v1") {
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast(3))
        }
        components.percentEncodedPath += "/v1/tools/tts"
        return components.url
    }

    func synthesize(text: String) -> AsyncThrowingStream<TTSAudioChunk, Error> {
        AsyncThrowingStream { continuation in
            do {
                var req = URLRequest(url: config.ttsURL)
                req.httpMethod = "POST"
                req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 120
                req.httpBody = try JSONEncoder().encode(TTSRequestBody(
                    text: text, voiceID: config.voiceID, format: "pcm", filterMarkdown: true))
                let task = hub.start(request: req, continuation: continuation)
                // 消费者取消（打断/挂断）→ 取消网络请求；didComplete 会清理流状态
                continuation.onTermination = { _ in task.cancel() }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private struct TTSRequestBody: Encodable {
        let text: String
        let voice_id: String
        let format: String
        let filter_markdown: Bool

        init(text: String, voiceID: String, format: String, filterMarkdown: Bool) {
            self.text = text
            self.voice_id = voiceID
            self.format = format
            self.filter_markdown = filterMarkdown
        }
    }
}

/// 引擎级共享流式会话：一个 delegate 会话复用整通通话的连接池（句间 TLS 不重握）。
/// 网络分片在 didReceive data 里直接产出，不做逐字节异步迭代。
///
/// 线程模型：delegate 回调在系统串行队列上依次到达；lock 只防 onTermination
/// （任意线程）与回调竞争 streams 表。continuation 本身线程安全。
private final class TTSStreamHub: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Stream {
        let continuation: AsyncThrowingStream<TTSAudioChunk, Error>.Continuation
        var expected: Int64 = -1        // Content-Length；-1 = chunked 未知
        var received: Int64 = 0
        var pending = Data()            // 未到 yield 阈值的累积（恒为偶数字节）
        var carry: UInt8?               // 奇数分片的半个 16bit 采样，拼进下一片
        var yieldedFirst = false
        var httpError: Error?
    }

    private let lock = NSLock()
    private var streams: [Int: Stream] = [:]
    private var session: URLSession!

    /// 首包 1024 字节 ≈ 21ms 音频：够覆盖网络抖动，又比旧 4096（85ms）快得多；
    /// 后续 4096 批量，减少播放器调度次数。
    private static let firstThreshold = 1024
    private static let nextThreshold = 4096

    init(configuration: URLSessionConfiguration) {
        super.init()
        // 复制注入配置（保留测试的 URLProtocol 桩）；delegateQueue nil = 系统串行队列
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func start(request: URLRequest,
               continuation: AsyncThrowingStream<TTSAudioChunk, Error>.Continuation) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        streams[task.taskIdentifier] = Stream(continuation: continuation)
        lock.unlock()
        task.resume()
        return task
    }

    /// 引擎销毁时调用：让在途任务收尾后释放 delegate，打破 session↔delegate 循环引用。
    func close() {
        session.finishTasksAndInvalidate()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        var disposition = URLSession.ResponseDisposition.allow
        lock.lock()
        if var stream = streams[dataTask.taskIdentifier] {
            if let http = response as? HTTPURLResponse {
                stream.expected = http.expectedContentLength
                if !(200..<300).contains(http.statusCode) {
                    stream.httpError = NSError(domain: "DeepSeekTTS", code: http.statusCode,
                                               userInfo: [NSLocalizedDescriptionKey:
                                                    "TTS 请求失败（HTTP \(http.statusCode)）"])
                    disposition = .cancel   // 错误体无需下载；didComplete 里抛 HTTP 错误
                }
            }
            streams[dataTask.taskIdentifier] = stream
        }
        lock.unlock()
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var stream = streams[dataTask.taskIdentifier], stream.httpError == nil else {
            lock.unlock()
            return
        }
        stream.received += Int64(data.count)
        var chunk = data
        // 16bit 采样对齐：网络分片可能在采样中间切开，半个字节留到下一片拼接，
        // 否则后续所有采样错位半字节 → 播放出来全是噪声。
        if let carry = stream.carry {
            chunk = Data([carry]) + chunk
            stream.carry = nil
        }
        if chunk.count % 2 != 0 {
            stream.carry = chunk.last
            chunk = chunk.dropLast()
        }
        stream.pending.append(chunk)
        let threshold = stream.yieldedFirst ? Self.nextThreshold : Self.firstThreshold
        var out: Data?
        if stream.pending.count >= threshold {
            out = stream.pending
            stream.pending = Data()
            stream.yieldedFirst = true
        }
        streams[dataTask.taskIdentifier] = stream
        let continuation = stream.continuation
        lock.unlock()
        if let out { continuation.yield(TTSAudioChunk(pcm: out)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let stream = streams.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()
        if let httpError = stream.httpError {
            stream.continuation.finish(throwing: httpError)
            return
        }
        if let error {
            // 消费者已取消时 continuation 已终止，finish 是空操作，不会误报
            stream.continuation.finish(throwing: error)
            return
        }
        // 文档要求：响应提前结束（字节数不足 Content-Length）视为失败
        if stream.expected > 0 && stream.received < stream.expected {
            stream.continuation.finish(throwing: NSError(domain: "DeepSeekTTS", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "TTS 音频中途断流（文档要求视为失败）"]))
            return
        }
        if !stream.pending.isEmpty {
            stream.continuation.yield(TTSAudioChunk(pcm: stream.pending))
        }
        stream.continuation.finish()
    }
}
