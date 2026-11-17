//
//  CallComparisonView.swift
//  FenShen
//
//  Created by 陆遥 on 2026/11/17.
//
//  TTS 对比模式页面：同一段文本分别用两条路径合成并播放——
//  · 本地 AVSpeechSynthesizer（完全离线）：onStart 回调 = 首音，speak 返回 = 总时长
//  · DeepSeek 云端 TTS（需 API Key + 联网）：首个 chunk 到达 = 首包，流结束 = 总时长
//  两条延迟都能看到，可各打 1–5 星（或跳过），保存进 CallMetricsStore
//  （Documents/call_comparisons.json），页面底部倒序展示历史记录。
//
//  实现思路：
//  · 两条路径状态完全独立（合成中 / 错误 / 结果），一个按钮一个异步任务，互不覆盖；
//  · 本地：每次 new 一个 LocalAVSpeechTTSEngine，Date 计时。onStart 是 @Sendable
//    同步回调不能直接写 @State，先记进线程安全的 FirstAudioBox（只认第一次写入），
//    speak 返回后再换算成毫秒；
//  · 云端：DeepSeekTTSStreamingEngine.synthesize 出流，边收边送 StreamingAudioPlayer
//    播放（play 内部惰性起 engine，入队即返回不阻塞收流）。播放器跨轮复用：
//    再次合成前先 stopAll() 清掉上一轮余音，播完自然结束不需要手动停；
//  · 两条都测过才开放打分区；新一轮测量会作废上一轮评分（两条必须配对保存）；
//  · 「保存记录」按钮打分/跳过（不打分）都能按，写 recordComparison；
//  · 历史直接读 store.comparisons 倒序展示，不重复查文件；
//  · 顶部常驻安全提示：云端要 Key + 联网；本地完全离线。
//
//  PhoneView 用法：CallComparisonView(apiKey: <用户配置的 Key>, baseURL: <用户配置的地址>)
//
//  疑点备忘（不改别人文件，集成时留意）：
//  · StreamingAudioPlayer.onFirstAudio 表示「真出声」，本页按需求定义用「首个 chunk
//    到达」当云端首包，两者略有差异（入队 ≠ 出声，一般差几十毫秒以内）；
//  · play 的注释写明「需要音频会话已激活」，本页在合成前用 try? 把会话切成
//    playback/spokenAudio：对比页不在通话中，不影响通话页自己的会话配置。

import AVFoundation
import SwiftUI

// MARK: - TTS 对比模式（本地 AVSpeech vs DeepSeek 云端）

@MainActor
struct CallComparisonView: View {
    // MARK: 依赖（PhoneView 传入；云端 URL 由 ttsURL(fromBase:) 推导）

    private let apiKey: String
    private let baseURL: String

    /// 指标落盘（保存对比记录 + 历史列表数据源）
    @ObservedObject private var store = CallMetricsStore.shared

    init(apiKey: String, baseURL: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    // MARK: 页面状态

    /// 预置默认对比文本，可编辑
    @State private var text = "你好，我是 DeepSeek。今天天气怎么样？"

    /// 两条路径各自的合成中标志（按钮转圈 + 禁用）
    @State private var isLocalRunning = false
    @State private var isCloudRunning = false

    /// 本轮测量结果（nil = 没测到）
    @State private var localFirstAudioMs: Double?
    @State private var localTotalMs: Double?
    @State private var cloudFirstPacketMs: Double?
    @State private var cloudTotalMs: Double?
    /// 是否完成过一次测量（打分区的开关，与结果是否为 nil 解耦）
    @State private var localMeasured = false
    @State private var cloudMeasured = false

    /// 各自的错误提示（橙色显示）
    @State private var localError: String?
    @State private var cloudError: String?

    /// 打分（nil = 未打分 = 跳过）
    @State private var localScore: Int?
    @State private var cloudScore: Int?
    /// 本轮是否已保存过（防重复保存）
    @State private var hasSavedThisRound = false

    /// 云端是否往播放器送过音频（本地开跑前据此决定要不要清掉云端余音，避免混音）
    @State private var cloudEverPlayed = false
    /// 播放器跨两次云端合成复用（再次合成前先 stopAll）
    @State private var player = StreamingAudioPlayer()

    /// 任一路径在合成就禁用两个按钮（避免本地人声和云端音频叠在一起放）
    private var busy: Bool { isLocalRunning || isCloudRunning }

    // MARK: 界面

    var body: some View {
        Form {
            // 顶部安全提示（常驻）
            Section {
                Label {
                    Text("云端合成需要已填 API Key 且联网；本地合成完全离线。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.orange)
                }
            }

            // 输入 + 两个合成按钮
            Section("对比文本") {
                TextField("要合成的文本", text: $text, axis: .vertical)
                    .lineLimit(2...5)

                Button {
                    Task { await runLocal() }
                } label: {
                    HStack {
                        if isLocalRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        Text("合成并播放（本地）")
                    }
                }
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await runCloud() }
                } label: {
                    HStack {
                        if isCloudRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "cloud.fill")
                        }
                        Text("合成并播放（DeepSeek）")
                    }
                }
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 本轮结果行
            if localMeasured || cloudMeasured {
                Section("本轮结果") {
                    if localMeasured {
                        Text("本地：首音 \(msText(localFirstAudioMs)) · 总时长 \(msText(localTotalMs))")
                            .font(.subheadline)
                            .monospacedDigit()
                    } else {
                        Text("本地：未测试").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if cloudMeasured {
                        Text("云端：首包 \(msText(cloudFirstPacketMs)) · 总时长 \(msText(cloudTotalMs))")
                            .font(.subheadline)
                            .monospacedDigit()
                    } else {
                        Text("云端：未测试").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let localError {
                        Text(localError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let cloudError {
                        Text(cloudError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // 打分区：两条都测过才出现
            if localMeasured && cloudMeasured {
                Section("主观评分（1–5 星，可跳过）") {
                    starPicker(title: "本地", score: $localScore)
                    starPicker(title: "云端", score: $cloudScore)
                    Button {
                        saveRecord()
                    } label: {
                        HStack {
                            Spacer()
                            Text(hasSavedThisRound ? "已保存 ✓" : "保存记录")
                            Spacer()
                        }
                    }
                    .disabled(hasSavedThisRound)
                    Text("不打分直接保存 = 跳过评分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 历史记录（倒序：最新在最上）
            Section("历史记录") {
                if store.comparisons.isEmpty {
                    Text("还没有对比记录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.comparisons.reversed()) { record in
                        historyRow(record)
                    }
                }
            }
        }
    }

    // MARK: - 本地路径：AVSpeechSynthesizer

    private func runLocal() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        localError = nil
        // 新一轮测量：清掉上一轮结果与评分（两条必须配对保存，旧评分不再成立）
        localFirstAudioMs = nil
        localTotalMs = nil
        localMeasured = false
        localScore = nil
        cloudScore = nil
        hasSavedThisRound = false
        // 上一轮云端的音频可能还在自然播放，先清掉避免混音
        if cloudEverPlayed { await player.stopAll() }

        isLocalRunning = true
        defer { isLocalRunning = false }
        do {
            activatePlaybackSession()
            // 每次新建一个引擎：speak 在整句念完（或取消）后才返回
            let engine = LocalAVSpeechTTSEngine()
            let firstAudio = FirstAudioBox()
            let start = Date()
            try await engine.speak(trimmed, onStart: { firstAudio.store(Date()) })
            let end = Date()
            // onStart 没触发（极端情况）时首音显示 "—"，不用假数据兜底
            localFirstAudioMs = firstAudio.value.map { $0.timeIntervalSince(start) * 1000 }
            localTotalMs = end.timeIntervalSince(start) * 1000
            localMeasured = true
        } catch {
            localError = "本地合成失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 云端路径：DeepSeek TTS 流式合成

    private func runCloud() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        cloudError = nil
        // 新一轮测量：清掉上一轮结果与评分（两条必须配对保存，旧评分不再成立）
        cloudFirstPacketMs = nil
        cloudTotalMs = nil
        cloudMeasured = false
        localScore = nil
        cloudScore = nil
        hasSavedThisRound = false

        // 参数检查：没填 Key / baseURL 不合法 → 直接橙色报错，不发请求
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cloudError = "云端合成失败：还没有填 API Key（设置 → API Key）"
            return
        }
        guard let ttsURL = DeepSeekTTSStreamingEngine.ttsURL(fromBase: baseURL) else {
            cloudError = "云端合成失败：baseURL「\(baseURL)」无法解析出合法地址"
            return
        }

        isCloudRunning = true
        defer { isCloudRunning = false }
        do {
            activatePlaybackSession()
            // 再次合成前先停掉上一轮（上一轮自然播完无需手动停，重播必须先清）
            await player.stopAll()
            let engine = DeepSeekTTSStreamingEngine(config: .init(apiKey: apiKey, ttsURL: ttsURL))
            let start = Date()
            var firstPacketAt: Date?
            // 边收流边送播放器：play 入队即返回，不阻塞收下一个分片
            for try await chunk in engine.synthesize(text: trimmed) {
                if firstPacketAt == nil { firstPacketAt = Date() }   // 首个 chunk 到达 = 首包
                try await player.play(pcm: chunk.pcm)                // 首次前 play 内部惰性起 engine
                cloudEverPlayed = true
            }
            // 流结束 = 总时长；播放器里已入队的音频继续自然播完，不用手动停
            cloudFirstPacketMs = firstPacketAt.map { $0.timeIntervalSince(start) * 1000 }
            cloudTotalMs = Date().timeIntervalSince(start) * 1000
            cloudMeasured = true
        } catch {
            // 中途出错把已入队的半截音频清掉，避免留下残音
            await player.stopAll()
            cloudError = "云端合成失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 打分 / 保存

    /// 一行星级选择：点第 n 颗 = n 分；再点同一颗取消（回到未打分）
    private func starPicker(title: String, score: Binding<Int?>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .frame(width: 36, alignment: .leading)
            ForEach(1...5, id: \.self) { star in
                Button {
                    score.wrappedValue = (score.wrappedValue == star) ? nil : star
                } label: {
                    Image(systemName: (score.wrappedValue ?? 0) >= star ? "star.fill" : "star")
                        .foregroundStyle(.yellow)
                        .font(.title3)
                }
                .buttonStyle(.plain)      // List 行内多按钮必须 plain，否则整行都算一个按钮
                .accessibilityLabel("\(title) \(star) 星")
            }
            Spacer()
        }
    }

    /// 保存本轮对比记录（打分或跳过都走这里）
    private func saveRecord() {
        store.recordComparison(CallMetricsStore.ComparisonRecord(
            text: text,
            localFirstAudioMs: localFirstAudioMs,
            localTotalMs: localTotalMs,
            cloudFirstPacketMs: cloudFirstPacketMs,
            cloudTotalMs: cloudTotalMs,
            localScore: localScore,
            cloudScore: cloudScore,
            at: Date()))
        hasSavedThisRound = true
    }

    // MARK: - 历史记录行

    private func historyRow(_ record: CallMetricsStore.ComparisonRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.at, format: .dateTime.month().day().hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("本地 \(scoreText(record.localScore)) · 云端 \(scoreText(record.cloudScore))")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            Text(String(record.text.prefix(20)))
                .font(.subheadline)
                .lineLimit(1)
            Text("首音：本地 \(msText(record.localFirstAudioMs)) · 云端 \(msText(record.cloudFirstPacketMs))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    // MARK: - 小工具

    /// 毫秒显示：nil 显示 "—"，四舍五入到整数毫秒
    private func msText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))ms"
    }

    /// 分数显示：未打分显示 "—"
    private func scoreText(_ score: Int?) -> String {
        guard let score else { return "—" }
        return "★\(score)"
    }

    /// 播放前把音频会话切成 playback/spokenAudio：对比页不在通话中，这样静音键
    /// 不会把播放吞掉；已激活时重复调用无害。失败不阻塞（try?），只影响能否出声。
    private func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }
}

// MARK: - 首音时间戳盒子（onStart 回调用）

/// onStart 是 @Sendable 同步回调，不能直接写 @State：先记进这个小盒子，
/// speak 返回后再取。只认第一次写入（首音只发生一次）。
private final class FirstAudioBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?

    func store(_ newDate: Date) {
        lock.lock()
        defer { lock.unlock() }
        if date == nil { date = newDate }
    }

    var value: Date? {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
}
