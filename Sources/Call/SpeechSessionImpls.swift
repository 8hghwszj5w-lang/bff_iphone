import AVFoundation
import Foundation
import Speech

// MARK: - 语音识别：iOS 26 用 SpeechAnalyzer/SpeechTranscriber，低版本回退 SFSpeechRecognizer
//
// 两个实现共同约束：
// · onEvent 只在主线程回调（协议约定）
// · start()/stop() 可反复调用；Legacy 每句换新请求，同一通话内 engine 不重启
// · 识别期间 mic 常开 → TTS 播放时依靠 voice processing 回声消除防止自听
//
// 工厂按系统版本选择；测试直接注入 Mock，不经过这里。

/// 组装会话。iOS 26+ 用新 API（更快、可离线、打断更灵敏），否则回退旧 API。
@MainActor
enum SpeechSessionFactory {
    static func makeBest() -> SpeechSession {
        if #available(iOS 26.0, *) {
            return ModernSpeechSession()
        } else {
            return LegacySpeechSession()
        }
    }
}

// MARK: - 不依赖麦克风/权限的生命周期状态（两种实现共用）

/// 启动前就占用代次；stop 既能结束收音，也能使尚在等待权限/模型下载的 start 失效。
struct SpeechSessionLifecycle {
    private(set) var sessionID: UUID?
    private(set) var isRunning = false

    mutating func beginStart() -> UUID? {
        guard sessionID == nil else { return nil }
        let id = UUID()
        sessionID = id
        return id
    }

    func isCurrent(_ id: UUID, requiringRunning: Bool = false) -> Bool {
        sessionID == id && (!requiringRunning || isRunning)
    }

    @discardableResult
    mutating func markRunning(_ id: UUID) -> Bool {
        guard isCurrent(id) else { return false }
        isRunning = true
        return true
    }

    /// 带代次的取消/失败只能清理自己的会话，不能误停后来启动的那次。
    @discardableResult
    mutating func invalidate(ifCurrent id: UUID? = nil) -> Bool {
        guard let current = sessionID, id == nil || id == current else { return false }
        sessionID = nil
        isRunning = false
        return true
    }
}

/// partial 只去重 partial；同文 final 仍须交付且只交付一次。
struct LegacySpeechRecognitionState {
    private(set) var roundID: UUID?
    private var lastPartial: String?

    mutating func beginRound() -> UUID {
        let id = UUID()
        roundID = id
        lastPartial = nil
        return id
    }

    mutating func consume(text: String, isFinal: Bool, roundID id: UUID) -> STTEvent? {
        guard roundID == id else { return nil }
        if isFinal {
            invalidate()
            return .final(text)
        }
        guard text != lastPartial else { return nil }
        lastPartial = text
        return .partial(text)
    }

    mutating func invalidate() {
        roundID = nil
        lastPartial = nil
    }
}

// MARK: - iOS 26+：SpeechAnalyzer + SpeechTranscriber（progressiveTranscription）

@available(iOS 26.0, *)
@MainActor
final class ModernSpeechSession: SpeechSession {
    var onEvent: (@MainActor (STTEvent) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var feedContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var lifecycle = SpeechSessionLifecycle()
    private var tapInstalled = false
    /// 已经以 final 事件发出去的累计字符数（新 API 的结果是全文累计，
    /// 需要在这里按句切分出"一句说完"事件，VM 才能按句回复）
    private var emittedCharCount = 0

    func start() async throws {
        try Task.checkCancellation()
        guard let sessionID = lifecycle.beginStart() else { return }

        do {
            try await withTaskCancellationHandler {
                let transcriber = SpeechTranscriber(
                    locale: Locale(identifier: "zh-CN"),
                    preset: .progressiveTranscription)   // 渐进式：边说边出临时字幕

                // 首次使用需要下载识别模型；每个挂起点后检查 stop/取消，防止迟到启动。
                let status = await AssetInventory.status(forModules: [transcriber])
                try checkStart(sessionID)
                if status != .installed {
                    let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                    try checkStart(sessionID)
                    if let request {
                        try await request.downloadAndInstall()
                        try checkStart(sessionID)
                    }
                }

                let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                feedContinuation = continuation
                self.transcriber = transcriber
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = analyzer
                emittedCharCount = 0

                // start 必须实际开始收音；失败时外层 catch 撤销 tap 和所有状态。
                try installTapAndStartEngine(continuation: continuation)
                try checkStart(sessionID)
                lifecycle.markRunning(sessionID)

                analyzerTask = Task { [weak self, stream] in
                    do {
                        try await analyzer.start(inputSequence: stream)
                    } catch {
                        self?.finishSession(ifCurrent: sessionID)
                    }
                }
                let terminators: Set<Character> = ["。", "！", "？", "…", "!", "?", ";", "\n"]
                resultsTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard !Task.isCancelled, let self,
                                  self.lifecycle.isCurrent(sessionID, requiringRunning: true) else { break }
                            let full = String(result.text.characters)
                            guard full.count > self.emittedCharCount else { continue }
                            let fresh = String(full.dropFirst(self.emittedCharCount))
                            if let last = fresh.last, terminators.contains(last) {
                                let sentence = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
                                self.emittedCharCount = full.count
                                if !sentence.isEmpty { self.onEvent?(.final(sentence)) }
                            } else {
                                self.onEvent?(.partial(fresh))
                            }
                        }
                    } catch {
                        // 取消和结果流失败都结束本代次，不保留已失去消费者的麦克风。
                    }
                    self?.finishSession(ifCurrent: sessionID)
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.finishSession(ifCurrent: sessionID) }
            }
        } catch {
            finishSession(ifCurrent: sessionID)
            throw error
        }
    }

    private func checkStart(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle.isCurrent(sessionID) else { throw CancellationError() }
    }

    func stop() async {
        finishSession()
    }

    private func finishSession(ifCurrent sessionID: UUID? = nil) {
        guard lifecycle.invalidate(ifCurrent: sessionID) else { return }
        feedContinuation?.finish()
        feedContinuation = nil
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        analyzerTask?.cancel()
        analyzerTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        emittedCharCount = 0
    }

    // engine 由本类自持（CallViewModel 不感知新/旧 API 差异）
    private let audioEngine = AVAudioEngine()

    private func installTapAndStartEngine(continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = audioEngine.inputNode
        // voice processing = 系统级回声消除，TTS 外放不会被当作用户说话
        try? input.setVoiceProcessingEnabled(true)
        input.installTap(onBus: 0, bufferSize: 2048,
                         format: input.outputFormat(forBus: 0)) { buffer, _ in
            // 固定绑定本次流；stop 后迟到的 tap 只能 yield 到已结束的旧流。
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }
}

// MARK: - iOS < 26：SFSpeechRecognizer 经典方案

/// audio tap 不在主线程，不能直接读写 MainActor 上的 request。
/// 每次 start 用独立 sink；换句时原子替换 request，stop 后旧 tap 不会喂进新会话。
private final class LegacySpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func replaceRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }
}

@MainActor
final class LegacySpeechSession: NSObject, SpeechSession {
    var onEvent: (@MainActor (STTEvent) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lifecycle = SpeechSessionLifecycle()
    private var recognitionState = LegacySpeechRecognitionState()
    private var restartTask: Task<Void, Never>?
    private var audioSink: LegacySpeechAudioSink?
    private var tapInstalled = false

    override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    func start() async throws {
        try Task.checkCancellation()
        guard let sessionID = lifecycle.beginStart() else { return }
        do {
            try await withTaskCancellationHandler {
                // 旧 API 需要显式的语音识别授权（iOS 26 新 API 不需要）。
                let status = await withCheckedContinuation { cont in
                    SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard lifecycle.isCurrent(sessionID) else { throw CancellationError() }
                guard status == .authorized else {
                    throw NSError(domain: "CallSTT", code: 401,
                                  userInfo: [NSLocalizedDescriptionKey: "没有语音识别权限：设置 → 隐私与安全性 → 语音识别"])
                }
                guard let recognizer, recognizer.isAvailable else {
                    throw NSError(domain: "CallSTT", code: 503,
                                  userInfo: [NSLocalizedDescriptionKey: "语音识别暂不可用（检查网络）"])
                }

                let sink = LegacySpeechAudioSink()
                audioSink = sink
                let input = audioEngine.inputNode
                try? input.setVoiceProcessingEnabled(true)   // 回声消除
                input.installTap(onBus: 0, bufferSize: 2048,
                                 format: input.outputFormat(forBus: 0)) { buffer, _ in
                    sink.append(buffer)
                }
                tapInstalled = true
                audioEngine.prepare()
                try audioEngine.start()
                try Task.checkCancellation()
                lifecycle.markRunning(sessionID)
                try startRecognitionRound(sessionID: sessionID)
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.finishSession(ifCurrent: sessionID) }
            }
        } catch {
            finishSession(ifCurrent: sessionID)
            throw error
        }
    }

    /// 仅轮换识别请求，不递归 start、不重复授权、不重启 engine。
    private func startRecognitionRound(sessionID: UUID) throws {
        guard lifecycle.isCurrent(sessionID, requiringRunning: true),
              recognitionState.roundID == nil else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "CallSTT", code: 503,
                          userInfo: [NSLocalizedDescriptionKey: "语音识别暂不可用（检查网络）"])
        }
        let roundID = recognitionState.beginRound()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        audioSink?.replaceRequest(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // 只把值类型跨线程传递，不把 Speech 框架的 result 对象送进 MainActor。
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.receive(text: text, isFinal: isFinal, failed: failed,
                              sessionID: sessionID, roundID: roundID)
            }
        }
    }

    private func receive(text: String?, isFinal: Bool, failed: Bool,
                         sessionID: UUID, roundID: UUID) {
        guard lifecycle.isCurrent(sessionID, requiringRunning: true),
              recognitionState.roundID == roundID else { return }
        let event = text.flatMap {
            recognitionState.consume(text: $0, isFinal: isFinal, roundID: roundID)
        }
        if isFinal {
            // consume 已使本轮失效，cancel 引发的迟到回调不会重入或影响下一句。
            finishRequest()
            if let event { onEvent?(event) }
            restartTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self,
                      self.lifecycle.isCurrent(sessionID, requiringRunning: true) else { return }
                self.restartTask = nil
                do {
                    try self.startRecognitionRound(sessionID: sessionID)
                } catch {
                    self.finishSession(ifCurrent: sessionID)
                }
            }
        } else if failed {
            // 错误不能无限自动重试；结束资源，外部可显式 start 再试。
            finishSession(ifCurrent: sessionID)
        } else if let event {
            onEvent?(event)
        }
    }

    func stop() async {
        finishSession()
    }

    private func finishRequest() {
        // 先断开 tap 的路由，确保 endAudio 后不再 append。
        audioSink?.replaceRequest(nil)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    private func finishSession(ifCurrent sessionID: UUID? = nil) {
        guard lifecycle.invalidate(ifCurrent: sessionID) else { return }
        recognitionState.invalidate()
        restartTask?.cancel()
        restartTask = nil
        finishRequest()
        audioSink = nil
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
