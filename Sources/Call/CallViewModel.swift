import AVFoundation
import Foundation
import Observation

// MARK: - 通话状态机：idle → preparing → listening ⇄ thinking → speaking
// 每个异步操作属于明确的通话/轮次。挂断或打断后，旧任务不能写回新状态。
@Observable
@MainActor
final class CallViewModel {
    private(set) var phase: CallPhase = .idle
    private(set) var liveTranscript = ""
    private(set) var replyText = ""
    private(set) var route: TTSRoute {
        didSet { TTSRoute.saved = route }
    }
    private(set) var lastMetrics: TurnMetrics?
    private(set) var degradationNote: String?
    private(set) var errorMessage: String?
    var isRecording: Bool { phase == .listening }

    @ObservationIgnored private(set) var llm: LLMClient
    @ObservationIgnored private(set) var localTTS: TTSEngine
    @ObservationIgnored private(set) var cloudTTS: TTSStreamingEngine?
    @ObservationIgnored private(set) var player: CallAudioPlayer
    @ObservationIgnored private(set) var speechSession: SpeechSession
    @ObservationIgnored private let recordMetrics: (TurnMetrics) -> Void

    @ObservationIgnored var requestPermissions: @Sendable () async -> String? = {
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? nil : "没有麦克风权限：请到 设置 → 隐私与安全性 → 麦克风 里允许「分身」。"
    }
    @ObservationIgnored var configureAudioSession: () throws -> Void = {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try session.setActive(true)
    }
    @ObservationIgnored var deactivateAudioSession: () -> Void = {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var callID: UUID?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var bargeInBaseline = 0
    @ObservationIgnored private var cloudDownUntil = Date.distantPast

    /// 轮次数据不共享，避免取消中的旧轮读取/覆盖新轮的文本、分句和首音指标。
    private final class Turn {
        let id: UUID
        let callID: UUID
        let start = Date()
        var firstAudioMs: Double?
        var queuedCloudAudio = false
        init(id: UUID, callID: UUID) { self.id = id; self.callID = callID }
    }

    init(llm: LLMClient, localTTS: TTSEngine, cloudTTS: (any TTSStreamingEngine)?,
         player: CallAudioPlayer, speechSession: SpeechSession,
         route: TTSRoute = TTSRoute.saved, recordMetrics: ((TurnMetrics) -> Void)? = nil) {
        self.llm = llm
        self.localTTS = localTTS
        self.cloudTTS = cloudTTS
        self.player = player
        self.speechSession = speechSession
        self.route = route
        self.recordMetrics = recordMetrics ?? { CallMetricsStore.shared.record($0) }
        speechSession.onEvent = { [weak self] event in self?.handleSpeechEvent(event) }
    }

    static func make(pipeline: Pipeline, settings: SettingsStore) -> CallViewModel {
        CallViewModel(
            llm: PipelineLLMClient(pipeline: pipeline),
            localTTS: LocalAVSpeechTTSEngine(),
            cloudTTS: DeepSeekTTSStreamingEngine(config: .init(
                apiKey: settings.apiKey,
                ttsURL: DeepSeekTTSStreamingEngine.ttsURL(fromBase: settings.baseURL)
                    ?? URL(string: "https://api.deepseek.com/v1/tools/tts")!)),
            player: StreamingAudioPlayer(), speechSession: SpeechSessionFactory.makeBest())
    }

    // MARK: 开始 / 挂断

    func startCall() {
        guard phase == .idle || isError(phase) else { return }
        if isError(phase) { shutdown() }
        let id = UUID()
        callID = id
        phase = .preparing
        let cleanup = cleanupTask
        startupTask = Task { [weak self] in
            await cleanup?.value
            guard let self, self.isCurrentCall(id), !Task.isCancelled else { return }
            await self.startCallAsync(id: id)
        }
    }

    func toggleRecording() {
        phase == .idle || isError(phase) ? startCall() : shutdown()
    }

    private func isCurrentCall(_ id: UUID) -> Bool { callID == id }
    private func isCurrent(_ turn: Turn) -> Bool { callID == turn.callID && turnID == turn.id }
    private func checkActive(_ turn: Turn) throws {
        try Task.checkCancellation()
        guard isCurrent(turn) else { throw CancellationError() }
    }

    private func startCallAsync(id: UUID) async {
        defer { if isCurrentCall(id) { startupTask = nil } }
        errorMessage = nil
        degradationNote = nil
        liveTranscript = ""
        replyText = ""
        let denied = await requestPermissions()
        guard isCurrentCall(id), !Task.isCancelled else { return }
        if let denied { failCall(denied); return }
        do {
            try configureAudioSession()
            do {
                try await speechSession.start()
            } catch {
                // iOS 26 语音转写不可用（locale 不支持 / 模型下载失败）→
                // Modern 会话抛错。自动换回系统经典识别方案重试一次，
                // 而不是让整通电话失败（旧方案在 iOS 26 上依然可用）。
                let fallbackCapable = (speechSession as? FallbackCapableSession)?.fallbackOnStartFailure == true
                guard fallbackCapable else { throw error }
                speechSession = LegacySpeechSession()
                speechSession.onEvent = { [weak self] event in self?.handleSpeechEvent(event) }
                degradationNote = "iOS 26 语音转写不可用，已切换系统经典识别方案"
                try await speechSession.start()
            }
            guard isCurrentCall(id), !Task.isCancelled else { return }
            phase = .listening
        } catch {
            guard isCurrentCall(id), !Task.isCancelled else { return }
            failCall("通话启动失败：\(error.localizedDescription)")
        }
    }

    /// 先同步失效任务身份，再停资源；快速重拨须等旧资源清理完成。
    func shutdown() {
        callID = nil
        turnID = nil
        let starting = startupTask
        startupTask = nil
        starting?.cancel()
        let turning = turnTask
        turnTask = nil
        turning?.cancel()
        let previous = cleanupTask
        cleanupTask = Task {
            await previous?.value
            await speechSession.stop()
            await player.shutdown()
            localTTS.stopSpeaking()
            // 取消不一定立即结束权限弹窗/识别安装，不能在旧启动完成前重开音频。
            await starting?.value
            await turning?.value
            deactivateAudioSession()
        }
        phase = .idle
        liveTranscript = ""
    }

    private func failCall(_ message: String) {
        shutdown()
        errorMessage = message
        phase = .error(message)
    }

    private func isError(_ phase: CallPhase) -> Bool {
        if case .error = phase { return true }
        return false
    }

    // MARK: STT 与打断

    private func handleSpeechEvent(_ event: STTEvent) {
        guard let callID, phase != .idle, phase != .preparing, !isError(phase) else { return }
        switch event {
        case .partial(let text):
            liveTranscript = text
            if phase == .speaking, text.count > bargeInBaseline + 1 { interruptNow() }
        case .final(let text):
            guard phase == .listening else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            liveTranscript = trimmed
            let turn = Turn(id: UUID(), callID: callID)
            turnID = turn.id
            // 必须在排 Task 之前占用轮次，同一 tick 的第二个 final 不得并行启动。
            phase = .thinking
            let cleanup = cleanupTask
            turnTask = Task { [weak self] in
                await cleanup?.value
                guard let self, self.isCurrent(turn), !Task.isCancelled else { return }
                await self.runTurn(trimmed, turn: turn)
            }
        }
    }

    private func interruptNow() {
        guard phase == .speaking else { return }
        turnID = nil
        let turning = turnTask
        turnTask = nil
        turning?.cancel()
        let previous = cleanupTask
        cleanupTask = Task {
            await previous?.value
            await player.stopAll()
            localTTS.stopSpeaking()
            await turning?.value
        }
        replyText = ""
        phase = .interrupted
        phase = .listening
    }

    // MARK: 一轮对话

    private struct SentenceResult {
        var degraded = false
        var ttsFirstPacketMs: Double?
        var actualPath = ""
    }

    private func runTurn(_ text: String, turn: Turn) async {
        var splitter = SentenceSplitter()
        var reply = ""
        replyText = ""
        var metrics = TurnMetrics(startedAt: turn.start, route: route.rawValue,
                                  actualPath: "", userText: text, replyText: "")
        var failure: Error?
        do {
            for try await delta in llm.streamReply(userText: text) {
                try checkActive(turn)
                if metrics.llmTTFTMs == nil { metrics.llmTTFTMs = TurnMetrics.elapsedMs(since: turn.start) }
                reply += delta
                replyText = reply
                for sentence in splitter.feed(delta) {
                    try checkActive(turn)
                    phase = .speaking
                    bargeInBaseline = liveTranscript.count
                    let result = try await speakSentence(sentence, turn: turn)
                    try checkActive(turn)
                    merge(result, turn: turn, into: &metrics)
                }
            }
            try checkActive(turn)
            if let tail = splitter.flush() {
                phase = .speaking
                bargeInBaseline = liveTranscript.count
                let result = try await speakSentence(tail, turn: turn)
                try checkActive(turn)
                merge(result, turn: turn, into: &metrics)
            }
            await player.awaitDrained()
            try checkActive(turn)
        } catch {
            if Task.isCancelled || !isCurrent(turn) || error is CancellationError {
                metrics.interrupted = true
            } else {
                failure = error
            }
        }
        metrics.replyText = reply
        metrics.e2eFirstAudioMs = turn.firstAudioMs
        metrics.totalMs = TurnMetrics.elapsedMs(since: turn.start)
        recordMetrics(metrics)
        // 打断但尚无下一轮时保留埋点；挂断/新轮之后的旧结果不能改 UI。
        if callID == turn.callID, turnID == turn.id || turnID == nil { lastMetrics = metrics }
        guard isCurrent(turn), !Task.isCancelled else { return }
        turnTask = nil
        turnID = nil
        if let failure { failCall("回复生成失败：\(failure.localizedDescription)"); return }
        phase = .listening
        liveTranscript = ""
    }

    private func merge(_ result: SentenceResult, turn: Turn, into metrics: inout TurnMetrics) {
        metrics.actualPath = result.actualPath
        if metrics.ttsFirstPacketMs == nil { metrics.ttsFirstPacketMs = result.ttsFirstPacketMs }
        metrics.e2eFirstAudioMs = turn.firstAudioMs
        if result.degraded { metrics.degraded = true }
    }

    private func speakSentence(_ sentence: String, turn: Turn) async throws -> SentenceResult {
        try checkActive(turn)
        var result = SentenceResult()
        if shouldUseCloud(), let cloud = cloudTTS {
            do {
                let start = Date()
                for try await chunk in cloud.synthesize(text: sentence) {
                    try checkActive(turn)
                    guard !chunk.pcm.isEmpty else { continue }
                    if result.ttsFirstPacketMs == nil {
                        result.ttsFirstPacketMs = TurnMetrics.elapsedMs(since: start)
                    }
                    try await player.play(pcm: chunk.pcm)
                    try checkActive(turn)
                    turn.queuedCloudAudio = true
                    markFirstAudio(turn)
                    result.actualPath = "cloud"
                }
                try checkActive(turn)
                return result
            } catch {
                try checkActive(turn) // URLError.cancelled 等取消不能误触发本地降级。
                if error is CancellationError { throw error }
                result.degraded = true
                cloudDownUntil = Date().addingTimeInterval(30)
                degradationNote = "云端合成失败（\(error.localizedDescription)），本句起已切换本地语音"
                if turn.queuedCloudAudio {
                    await player.stopAll()
                    try checkActive(turn)
                    turn.queuedCloudAudio = false
                }
            }
        }
        // 正常云转本地：等上一句云端音频播完，不让两套播放器重叠出声。
        if turn.queuedCloudAudio {
            await player.awaitDrained()
            try checkActive(turn)
            turn.queuedCloudAudio = false
        }
        result.actualPath = result.degraded ? "local-fallback" : "local"
        try await localTTS.speak(sentence, onStart: { [weak self] in
            Task { @MainActor in
                guard let self, self.isCurrent(turn) else { return }
                self.markFirstAudio(turn)
            }
        })
        try checkActive(turn)
        return result
    }

    private func shouldUseCloud() -> Bool {
        guard cloudTTS != nil else { return false }
        switch route {
        case .local: return false
        case .deepSeek, .autoFallback: return Date() >= cloudDownUntil
        }
    }

    private func markFirstAudio(_ turn: Turn) {
        guard isCurrent(turn), turn.firstAudioMs == nil else { return }
        turn.firstAudioMs = TurnMetrics.elapsedMs(since: turn.start)
    }

    func updateRoute(_ newRoute: TTSRoute) {
        route = newRoute
        cloudDownUntil = .distantPast
        degradationNote = nil
    }
}
