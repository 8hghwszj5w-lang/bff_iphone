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

// MARK: - 音频环境事件（来电打断 / 路由切换 / 媒体服务失效）
//
// 真机上通话最常见的闪退不是 Swift 代码崩，而是：来电、闹钟、Siri 打断或
// 耳机/蓝牙插拔后，AVAudioEngine 的 IO 线程带着失效的音频对象继续跑，
// 触发 CoreAudio 底层异常（com.apple.coreaudio.avfaudio / AURemoteIO 崩溃，
// 没有 Swift 栈可捕获）。所以必须在事件到达的第一时间停 tap/engine，
// 把状态机收干净，再决定「结束通话并提示」还是「跟随新路由自动重启」。

/// 纯逻辑判定：给定环境事件 + 当前收音状态 → 应对动作。离线可测。
struct AudioEnvironmentPolicy {
    enum Event: Equatable {
        case interruptionBegan         // 来电 / 闹钟 / Siri 打断
        case mediaServicesInvalidated  // 系统音频服务失效或重启（音频对象全体作废）
        case routeChanged              // 耳机 / 蓝牙插拔
    }
    enum Action: Equatable {
        case endAndNotify(String)      // 结束收音并把提示交给 VM 结束通话
        case restart                   // 结束当前代次后立刻按新路由重启收音
        case ignore
    }

    /// captureWanted：本代次是否期望收音。VM 主动 stop 后为 false，用于忽略
    /// 挂断之后才送达的迟到事件，防止通话被「复活」或出现僵尸重启。
    func action(for event: Event, captureWanted: Bool, isRunning: Bool) -> Action {
        // 没在收音（准备中 / 已挂断）时任何事件都不动作：启动期间的
        // setActive(true) 也可能触发路由变化通知，不能误杀正在启动的会话。
        guard captureWanted else { return .ignore }
        switch event {
        case .interruptionBegan:
            // 打断期间音频对象不可用，继续持有只会埋雷；结束通话让用户重新开始。
            // （打断结束的自动续播需要完整重建引擎，风险大于收益，暂不做）
            return .endAndNotify("通话被来电或其他应用打断，已结束，请重新开始")
        case .mediaServicesInvalidated:
            return .endAndNotify("系统音频服务异常，通话已结束，请重新开始")
        case .routeChanged:
            // 只有真正跑起来的收音才需要跟随路由重启；准备中的变化无害，忽略。
            return isRunning ? .restart : .ignore
        }
    }
}

/// 订阅系统音频环境通知，统一投回主线程。会话持有它，释放时自动注销。
@MainActor
final class AudioEnvironmentWatcher {
    private var tokens: [NSObjectProtocol] = []

    init(onInterruptionBegan: @escaping @MainActor () -> Void,
         onRouteChanged: @escaping @MainActor () -> Void,
         onMediaServicesInvalidated: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        // interruption 的 .began/.ended 在这里分流：.ended 不续播（见策略注释）。
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in onInterruptionBegan() }
        })
        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
            Task { @MainActor in onRouteChanged() }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in onMediaServicesInvalidated() }
            })
        }
    }

    deinit {
        // removeObserver 线程安全；通知可能在任意线程投递，不能等主线程。
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

/// installTap 对 0Hz / 0 声道的输入格式会直接抛 ObjC 异常（无法 catch → 闪退）。
/// 音频会话未激活、麦克风路由缺失、被其他引擎占用时都可能出现这种格式，
/// 必须先校验，把崩溃转换成可捕获的错误（走既有的 failCall / 回退路径）。
private func validatedMicFormat(of node: AVAudioInputNode) throws -> AVAudioFormat {
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        throw NSError(domain: "CallSTT", code: 502, userInfo: [
            NSLocalizedDescriptionKey: "麦克风输入暂不可用（音频会话未就绪或被占用），请重试"])
    }
    return format
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

/// 启动失败时是否允许 CallViewModel 自动回退到 Legacy 会话。
/// 只有 iOS 26 的 ModernSpeechSession 需要这个标记（用协议避免在非门控代码里
/// 直接引用带 @available(iOS 26) 的类型）。
protocol FallbackCapableSession: SpeechSession {
    var fallbackOnStartFailure: Bool { get }
}

// MARK: - iOS 26+：SpeechAnalyzer + SpeechTranscriber（progressiveTranscription）

@available(iOS 26.0, *)
@MainActor
final class ModernSpeechSession: SpeechSession, FallbackCapableSession {
    var onEvent: (@MainActor (STTEvent) -> Void)?
    var onInvalidated: (@MainActor (String) -> Void)?

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
    /// 本代次是否期望收音：VM 主动 stop / 打断收尾后置 false，
    /// 用于忽略迟到事件、阻止重启任务把已挂断的通话复活。
    private var wantsCapture = false
    private let policy = AudioEnvironmentPolicy()
    /// 惰性创建：闭包要捕获 self，只能在初始化完成后构建；
    /// start() 里首次访问时才订阅系统通知。
    private lazy var environmentWatcher = AudioEnvironmentWatcher(
        onInterruptionBegan: { [weak self] in self?.handleEnvironmentEvent(.interruptionBegan) },
        onRouteChanged: { [weak self] in self?.handleEnvironmentEvent(.routeChanged) },
        onMediaServicesInvalidated: { [weak self] in self?.handleEnvironmentEvent(.mediaServicesInvalidated) })

    func start() async throws {
        try Task.checkCancellation()
        _ = environmentWatcher   // 进入会话即订阅环境通知（惰性属性的首次实例化）
        wantsCapture = true
        guard let sessionID = lifecycle.beginStart() else { return }

        do {
            try await withTaskCancellationHandler {
                // ⚠️ 闪退修复：SpeechTranscriber(locale:) 在 locale 不被支持时是
                // 硬 trap（无法 catch，直接崩）——部分 iOS 26.0 设备/所有模拟器的
                // zh-CN 转写不在支持列表里。构造前必须先用两个静态检查守卫。
                // 文档：SpeechTranscriber.isAvailable / supportedLocale(equivalentTo:)
                guard SpeechTranscriber.isAvailable else {
                    throw NSError(domain: "CallSTT", code: 422, userInfo: [
                        NSLocalizedDescriptionKey: "此系统的 iOS 26 语音转写不可用，正在回退旧识别方案…"])
                }
                guard let mapped = await SpeechTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: "zh-CN")) else {
                    throw NSError(domain: "CallSTT", code: 422, userInfo: [
                        NSLocalizedDescriptionKey: "此系统的 iOS 26 语音转写不支持中文，正在回退旧识别方案…"])
                }

                let transcriber = SpeechTranscriber(
                    locale: mapped,
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
                        // analyzer 起不来：结束本代次；若通话仍在进行（非 VM 取消），
                        // 通知 VM 结束通话，避免「界面还在听、麦克风已死」的僵尸态。
                        self?.finishSession(ifCurrent: sessionID, notifyIfOrphaned: true)
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
                    self?.finishSession(ifCurrent: sessionID, notifyIfOrphaned: true)
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
        wantsCapture = false
        finishSession()
    }

    /// - notifyIfOrphaned: 结束后若通话仍期望收音（wantsCapture == true），
    ///   说明这是一次「内部失败导致的静默断麦」，通知 VM 以明确文案结束通话。
    ///   VM 主动 stop 路径会先把 wantsCapture 置 false，不会重复提示。
    private func finishSession(ifCurrent sessionID: UUID? = nil, notifyIfOrphaned: Bool = false) {
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
        if notifyIfOrphaned, wantsCapture {
            onInvalidated?("语音识别已中断，请重新开始通话")
        }
    }

    // MARK: 环境事件（打断 / 路由切换 / 媒体服务失效）

    private func handleEnvironmentEvent(_ event: AudioEnvironmentPolicy.Event) {
        switch policy.action(for: event, captureWanted: wantsCapture, isRunning: lifecycle.isRunning) {
        case .ignore:
            return
        case .endAndNotify(let note):
            wantsCapture = false
            finishSession()
            onInvalidated?(note)
        case .restart:
            restartCapture()
        }
    }

    /// 路由切换（耳机/蓝牙插拔）：先干净结束本代次（停 tap/engine），再重新走
    /// start 流程跟随新路由。重启期间用户挂断（wantsCapture=false）则直接放弃；
    /// 打断等其他环境事件抢先结束通话时不再重复提示。
    private func restartCapture() {
        finishSession()
        Task { @MainActor [weak self] in
            guard let self, self.wantsCapture else { return }
            do {
                try await self.start()
            } catch {
                guard self.wantsCapture else { return }
                self.onInvalidated?("音频设备切换后收音未能恢复，请重新开始通话")
            }
        }
    }

    // engine 由本类自持（CallViewModel 不感知新/旧 API 差异）
    private let audioEngine = AVAudioEngine()

    /// Modern 会话启动失败（locale 不支持 / 模型不可用）时允许 VM 回退旧方案
    var fallbackOnStartFailure: Bool { true }

    private func installTapAndStartEngine(continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = audioEngine.inputNode
        // voice processing = 系统级回声消除，TTS 外放不会被当作用户说话
        try? input.setVoiceProcessingEnabled(true)
        // installTap 对非法输入格式是 ObjC 硬 trap；先校验，失败走可捕获错误路径
        let tapFormat = try validatedMicFormat(of: input)
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { buffer, _ in
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
    var onInvalidated: (@MainActor (String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lifecycle = SpeechSessionLifecycle()
    private var recognitionState = LegacySpeechRecognitionState()
    private var restartTask: Task<Void, Never>?
    private var audioSink: LegacySpeechAudioSink?
    private var tapInstalled = false
    /// 本代次是否期望收音（语义与 Modern 会话一致）
    private var wantsCapture = false
    private let policy = AudioEnvironmentPolicy()
    /// 惰性创建（原因同 Modern 会话）；start() 里首次访问时才订阅系统通知
    private lazy var environmentWatcher = AudioEnvironmentWatcher(
        onInterruptionBegan: { [weak self] in self?.handleEnvironmentEvent(.interruptionBegan) },
        onRouteChanged: { [weak self] in self?.handleEnvironmentEvent(.routeChanged) },
        onMediaServicesInvalidated: { [weak self] in self?.handleEnvironmentEvent(.mediaServicesInvalidated) })

    override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    func start() async throws {
        try Task.checkCancellation()
        _ = environmentWatcher   // 进入会话即订阅环境通知
        wantsCapture = true
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
                // installTap 对非法输入格式是 ObjC 硬 trap；先校验再安装
                let tapFormat = try validatedMicFormat(of: input)
                input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { buffer, _ in
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
        restartTask?.cancel()   // 迟到的旧重启任务不能再占住这个槽位
        restartTask = nil
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
                    // 换句时识别已不可用（断网等）：结束收音并告知 VM，
                    // 避免「界面在听、永远等不到下一句」的僵尸通话。
                    self.finishSession(ifCurrent: sessionID, notifyIfOrphaned: true)
                }
            }
        } else if failed {
            // 错误不能无限自动重试；结束资源并让 VM 以明确文案结束通话
            // （此前是静默结束，界面仍显示「在听」，实际麦克风已死）。
            finishSession(ifCurrent: sessionID, notifyIfOrphaned: true)
        } else if let event {
            onEvent?(event)
        }
    }

    func stop() async {
        wantsCapture = false
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

    /// - notifyIfOrphaned: 语义与 Modern 会话一致——内部失败导致的断麦要告知 VM。
    private func finishSession(ifCurrent sessionID: UUID? = nil, notifyIfOrphaned: Bool = false) {
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
        if notifyIfOrphaned, wantsCapture {
            onInvalidated?("语音识别已中断，请重新开始通话")
        }
    }

    // MARK: 环境事件（打断 / 路由切换 / 媒体服务失效）

    private func handleEnvironmentEvent(_ event: AudioEnvironmentPolicy.Event) {
        switch policy.action(for: event, captureWanted: wantsCapture, isRunning: lifecycle.isRunning) {
        case .ignore:
            return
        case .endAndNotify(let note):
            wantsCapture = false
            finishSession()
            onInvalidated?(note)
        case .restart:
            restartCapture()
        }
    }

    /// 路由切换：干净结束后重新 start（已授权，不会再弹框；engine/tap 全部重建）。
    /// 期间用户挂断或其他事件抢先结束通话时不再重复提示。
    private func restartCapture() {
        finishSession()
        Task { @MainActor [weak self] in
            guard let self, self.wantsCapture else { return }
            do {
                try await self.start()
            } catch {
                guard self.wantsCapture else { return }
                self.onInvalidated?("音频设备切换后收音未能恢复，请重新开始通话")
            }
        }
    }
}
