import AVFoundation
import Foundation

// MARK: - 通话功能共享类型：路由开关 / 状态机 / 分句 / 埋点
//
// 两条 TTS 路径（见 CallViewModel）：
// · local     本地 STT → LLM → AVSpeechSynthesizer（优先 enhanced/premium 中文音色）
// · deepSeek  本地 STT → LLM 流式文本 → DeepSeek TTS API（POST /v1/tools/tts，
//             响应体流式 24kHz/16bit/单声道 PCM）→ 流式播放
// · autoFallback  先试 deepSeek，失败自动降级 local（无感）

// MARK: - 音频会话激活（主线程不阻塞、永不挂起）
//
// 两条约束决定了这里的实现：
// ① iOS 27 起系统对「主线程」同步 setActive 发出警告（AVAudioSession_iOS.mm:978）：
//    路由协商（尤其蓝牙）可能阻塞主线程数百毫秒 → 通话启动/挂断时 UI 卡顿。
// ② iOS 27 新增的异步 activate/deactivate API 在 27.3 beta 真机上完成回调
//    不触发 → 启动任务永久挂起 → 清理任务等它收尾 → 之后每次重拨都卡死，
//    只能重装 App。beta 新 API 不可依赖。
//
// 方案：AVAudioSession 线程安全，把同步 setActive 放到后台线程执行——
// 不阻塞主线程（警告只针对主线程调用）、不依赖任何新 API、同步调用必然
// 返回（成功或抛错），结构上不存在永久挂起路径。全系统版本同一行为。
enum AudioSessionActivation {
    /// 激活会话。失败抛错（调用方决定降级/提示）；任务取消不会中断激活本身，
    /// 续体必然被 resume（不会泄漏）；陈旧启动由调用方的代次检查拦截。
    static func activate(_ session: AVAudioSession) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) {
                do {
                    try session.setActive(true)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 去激活会话（通知被打断的应用可以续播）。失败不抛错：挂断清理必须走完。
    static func deactivate(_ session: AVAudioSession) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .userInitiated) {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                cont.resume()
            }
        }
    }
}

/// TTS 路由开关（运行时可切，不必重启通话——下一句就用新路径）
enum TTSRoute: String, CaseIterable, Identifiable {
    case local
    case deepSeek
    case autoFallback

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .local: return "本地语音"
        case .deepSeek: return "DeepSeek 语音"
        case .autoFallback: return "自动降级"
        }
    }

    /// 持久化到 UserDefaults（切换通话也不丢）
    static var saved: TTSRoute {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "call.ttsRoute"),
                  let route = TTSRoute(rawValue: raw) else { return .autoFallback }
            return route
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "call.ttsRoute") }
    }
}

/// 通话状态机（状态迁移只在 CallViewModel 内发生）
enum CallPhase: Equatable {
    case idle          // 未开始
    case preparing     // 权限/音频会话/识别引擎准备中
    case listening     // 收音中（实时字幕更新）
    case thinking      // 文字已给 LLM，等待流式文本（TTFT 计时中）
    case speaking      // TTS 播放中（可被打断）
    case interrupted   // 用户开口打断了 TTS（短暂态，随即转 listening）
    case error(String) // 不可继续的错误（挂断态）

    var isBusy: Bool { self == .thinking || self == .speaking }
}

// MARK: - 流式文本按句切分（TTS 按句合成才能"边生成边说话"）

/// 从 LLM 的字符增量里切出完整句子。
/// 规则：中英常见句末标点 + 换行；"点号两侧都是数字"（3.14 / 2.5）不当句号。
///
/// 性能：只扫描本次新到的字符。缓冲里留存的字符判定已定型——唯一依赖上下文的
/// 是「.」（需要前后邻字符），而旧规则下缓冲末尾的「.」因缺后继会被立即当句末
/// 切走，不会留存；留存字符的邻字符不会再变，无需每片重扫全缓冲。
struct SentenceSplitter {
    /// 尚未凑满一句的尾巴（只含已判定为非句末的字符）
    private var chars: [Character] = []
    /// 想调整切句粒度（比如把逗号也切开换更快首音但更生硬）改这个集合
    private let terminators: Set<Character> = ["。", "！", "？", "；", "…", "\n", "!", "?", ";"]

    /// 喂入增量，返回本次凑齐的完整句子（可能 0 ~ 多条）
    mutating func feed(_ delta: String) -> [String] {
        let oldCount = chars.count
        chars.append(contentsOf: delta)
        var sentences: [String] = []
        var segmentStart = 0
        var i = oldCount
        while i < chars.count {
            let ch = chars[i]
            let isSentenceEnd = terminators.contains(ch)
                || (ch == "." && !(i > 0 && chars[i - 1].isNumber
                                   && i + 1 < chars.count && chars[i + 1].isNumber))
            if isSentenceEnd {
                let sentence = String(chars[segmentStart...i])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                segmentStart = i + 1
            }
            i += 1
        }
        if segmentStart > 0 { chars.removeFirst(segmentStart) }
        return sentences
    }

    /// 流结束后把没凑满一句的尾巴交出来
    mutating func flush() -> String? {
        let tail = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        chars = []
        return tail.isEmpty ? nil : tail
    }

    mutating func reset() { chars = [] }
}

// MARK: - 延迟埋点（TTS 首包 / LLM TTFT / 端到端首音）

/// 一轮对话的耗时指标。三个关键数字：
/// · llmTTFTMs        首个文本增量到达（模型首字延迟）
/// · ttsFirstPacketMs 云端路径：TTS 音频首包到达（本地路径无此概念，为 nil）
/// · e2eFirstAudioMs  用户说完 → 听到第一个声音（体验上最重要的数字）
struct TurnMetrics: Codable, Identifiable, Equatable {
    var id = UUID()
    var startedAt: Date
    var route: String                 // 请求的路由（local/deepSeek/autoFallback）
    var actualPath: String            // 实际走的路径：cloud / local / local-fallback
    var userText: String
    var replyText: String
    var llmTTFTMs: Double?
    var ttsFirstPacketMs: Double?
    var e2eFirstAudioMs: Double?
    var totalMs: Double?
    var interrupted = false           // 是否被用户开口打断
    var degraded = false              // 云端失败是否降级到了本地

    static func elapsedMs(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000
    }
}

/// 指标落盘：Documents/call_metrics.json（轮次）与 call_comparisons.json（对比记录），
/// 都是原子写。对比模式与"评分"记录也放这里。
@MainActor
final class CallMetricsStore: ObservableObject {
    static let shared = CallMetricsStore()

    struct ComparisonRecord: Codable, Identifiable {
        var id = UUID()
        var text: String
        var localFirstAudioMs: Double?
        var localTotalMs: Double?
        var cloudFirstPacketMs: Double?
        var cloudTotalMs: Double?
        var localScore: Int?            // 用户手动打分 1–5
        var cloudScore: Int?
        var at: Date
    }

    private let turnsURL: URL
    private let comparisonsURL: URL
    @Published private(set) var turns: [TurnMetrics] = []
    @Published private(set) var comparisons: [ComparisonRecord] = []

    init(directory: URL? = nil) {
        let docs = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        turnsURL = docs.appendingPathComponent("call_metrics.json")
        comparisonsURL = docs.appendingPathComponent("call_comparisons.json")
        if let data = try? Data(contentsOf: turnsURL),
           let decoded = try? JSONDecoder().decode([TurnMetrics].self, from: data) {
            turns = decoded
        }
        if let data = try? Data(contentsOf: comparisonsURL),
           let decoded = try? JSONDecoder().decode([ComparisonRecord].self, from: data) {
            comparisons = decoded
        }
    }

    private func write<T: Encodable>(_ value: [T], to url: URL) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func record(_ turn: TurnMetrics) {
        turns.append(turn)
        // 只留最近 200 轮，防止无限膨胀
        if turns.count > 200 { turns.removeFirst(turns.count - 200) }
        write(turns, to: turnsURL)
    }

    func recordComparison(_ record: ComparisonRecord) {
        comparisons.append(record)
        write(Array(comparisons.suffix(50)), to: comparisonsURL)
    }
}
