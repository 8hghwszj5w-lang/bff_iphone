import AVFoundation
import Foundation

// MARK: - 通话五大组件的协议抽象
//
// 全部协议化是为了：① 两条路径可独立替换；② 单元测试用 Mock 不碰真音频；
// ③ 云端失败时 CallViewModel 能"换个引擎继续说"，界面无感。
//
// LLMClient            流式文本（适配现有 Pipeline，保留人设/记忆/联网搜索）
// TTSEngine            本地合成（文本进、音频从喇叭出，内部就是 AVSpeechSynthesizer）
// TTSStreamingEngine   云端流式合成（文本进、音频分片流出来）
// CallAudioPlayer      音频分片顺序播放（PCM 流 / 挂起清理）
// SpeechSession        语音识别会话（iOS 26 SpeechAnalyzer 优先，低版本回退 SFSpeechRecognizer）

/// LLM 流式客户端。一次 runTurn 对应一个 stream；取消 stream 即取消网络请求
/// （DeepSeekClient.ask 内部有 Task.checkCancellation，取消会一路传导到 URLSession）。
protocol LLMClient: Sendable {
    func streamReply(userText: String) -> AsyncThrowingStream<String, Error>
}

/// 本地 TTS：文本 → 喇叭。speak 在整句念完（或被取消）后才返回，天然保证句序。
/// 与 SpeechSession 一致标 @MainActor：合成器/续体只在主线程访问，避免跨隔离竞争。
@MainActor
protocol TTSEngine: AnyObject {
    /// - onStart: 首声回调（本地路径的"首包"概念，用于端到端首音埋点）
    func speak(_ text: String, onStart: (@Sendable () -> Void)?) async throws
    /// 立即停止（打断/挂断）。挂起的 speak 以 CancellationError 结束
    func stopSpeaking()
}

/// 云端流式 TTS：文本 → 音频分片异步流（每片是 24kHz/16bit/单声道 PCM 字节）
protocol TTSStreamingEngine: Sendable {
    var name: String { get }
    func synthesize(text: String) -> AsyncThrowingStream<TTSAudioChunk, Error>
}

struct TTSAudioChunk: Sendable {
    /// 原始 PCM 字节（Int16 小端、24kHz、单声道）
    var pcm: Data
}

/// 语音识别会话。事件在主线程回调；start/stop 可反复调用（一轮一轮用）。
@MainActor
protocol SpeechSession: AnyObject {
    /// partial：实时临时字幕；final：一句说完。speaking 期间的 partial 用于打断检测
    var onEvent: (@MainActor (STTEvent) -> Void)? { get set }
    /// 环境事件回调：来电打断、耳机插拔后自动重启失败、识别内部失败导致收音
    /// 结束时触发，参数是可直接展示给用户的说明。VM 主动 stop() 不触发。
    /// （不触发就会产生「界面显示通话中、麦克风已死」的僵尸通话）
    var onInvalidated: (@MainActor (String) -> Void)? { get set }
    /// 通话期间可复用的音频引擎：TTS 播放节点接入同一引擎。
    /// 双引擎（播放器自建 + 麦克风引擎）在 voice-processing 会话里会争抢 IO：
    /// 合成音听不到、播放完成回调不触发（awaitDrained 卡死 → 多轮对话不可用）、
    /// 引擎反复启停爆音。单引擎还让系统回声消除把 TTS 外放正确计入参考信号。
    var sharedAudioEngine: AVAudioEngine? { get }
    func start() async throws
    func stop() async
}

extension SpeechSession {
    /// 默认空实现：单元测试的 Mock / 不关心的实现无需暴露引擎。
    var onInvalidated: (@MainActor (String) -> Void)? {
        get { nil }
        set {}
    }

    /// 默认不暴露引擎（自建播放引擎的实现照旧）。
    var sharedAudioEngine: AVAudioEngine? { nil }
}

enum STTEvent {
    case partial(String)
    case final(String)
}

/// 音频播放器：云端 PCM 分片顺序入队；stop 清空未播内容（打断用）
/// 注：首音埋点不经过播放器——云端路径用首包到达、本地路径用合成器 didStart，
/// 都在 CallViewModel.speakSentence 里直接记录（入队时刻≈出声时刻，误差几十毫秒内）。
protocol CallAudioPlayer: AnyObject {
    /// 首次调用会启动底层 engine；返回即已入队（不是已播完）
    func play(pcm: Data) async throws
    /// 丢弃所有已入队未播放的音频
    func stopAll() async
    /// 等待已入队内容全部播完（判断一轮 TTS 结束）
    func awaitDrained() async
    /// 退出通话：丢弃待播内容并释放底层音频资源（引擎/节点）
    func shutdown() async
}

extension CallAudioPlayer {
    /// 没有独立音频引擎的实现只需清空待播内容。
    func shutdown() async { await stopAll() }
}
