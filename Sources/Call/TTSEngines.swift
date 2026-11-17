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
        utterance.voice = Self.preferredChineseVoice()
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
    static func preferredChineseVoice() -> AVSpeechSynthesisVoice? {
        let zh = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        return zh.first { $0.quality == .premium }
            ?? zh.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }
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

final class DeepSeekTTSStreamingEngine: TTSStreamingEngine, Sendable {
    let name = "DeepSeek TTS"

    struct Config: Sendable {
        var apiKey: String
        var ttsURL: URL
        var voiceID: String = "stella"      // stella(女声,默认) / tide(男声)
        var session: URLSession = .shared
    }

    private let config: Config

    init(config: Config) {
        self.config = config
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
            let task = Task {
                do {
                    var req = URLRequest(url: config.ttsURL)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 120
                    req.httpBody = try JSONEncoder().encode(TTSRequestBody(
                        text: text, voiceID: config.voiceID, format: "pcm", filterMarkdown: true))

                    let (bytes, response) = try await config.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let http = response as? HTTPURLResponse
                        // 错误体是 JSON（也可能不是），尽力解析出 message
                        throw NSError(domain: "DeepSeekTTS", code: http?.statusCode ?? -1,
                                      userInfo: [NSLocalizedDescriptionKey:
                                            "TTS 请求失败（HTTP \(http?.statusCode ?? -1)）"])
                    }

                    // 文档要求：响应提前结束（字节数不足 Content-Length）视为失败
                    let expected = http.expectedContentLength   // -1 = 未知（chunked）
                    var received = 0
                    var buffer = Data()
                    var iterator = bytes.makeAsyncIterator()
                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        received += 1
                        if buffer.count >= 4096 {
                            continuation.yield(TTSAudioChunk(pcm: buffer))
                            buffer = Data()
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(TTSAudioChunk(pcm: buffer)) }
                    if expected > 0 && received < expected {
                        throw NSError(domain: "DeepSeekTTS", code: -2,
                                      userInfo: [NSLocalizedDescriptionKey: "TTS 音频中途断流（文档要求视为失败）"])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
