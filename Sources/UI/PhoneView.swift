//
//  PhoneView.swift
//  FenShen
//
//  Created by 陆遥 on 2026/11/17.
//
//  语音通话界面（纯 UI 薄层）。状态机、双 TTS 路径、开口打断、云端降级、
//  延迟埋点的全部逻辑在 Sources/Call/CallViewModel.swift 的文件头注释里，
//  这里不复述，只负责三件事：
//
//  · 生命周期：onAppear 建 CallViewModel / onDisappear shutdown()
//    （验收项：退出页面必须清干净录音、TTS、网络任务——shutdown 幂等，可重复调）
//  · 把 VM 的可观察状态翻译成旧版视觉：状态圆圈 + 字幕气泡 + 大按钮
//  · 两个入口：语音路径切换（Picker → updateRoute，不重启通话）、
//    对比模式（工具栏 → CallComparisonView sheet，由并行开发提供）
//
//  想改外观去哪改：
//  · 状态圆圈的颜色 / 图标 / 文案 → CallStageView 的 statusColor / statusIcon / statusText
//  · 字幕气泡样式               → CallStageView 的 subtitleArea
//  · 延迟指标显示哪些数字       → CallStageView 的 metricsLine（含义见 CallCore.TurnMetrics）
//  · 想在通话里加新控件         → CallStageView.body 里加，绑定 vm 的对应可观察属性即可
//

import SwiftUI

// MARK: - 入口（ChatView 以 .sheet { PhoneView() } 拉起）

struct PhoneView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    // CallViewModel 是 @Observable：用 @State 持有就能被 SwiftUI 观察
    // （不是 ObservableObject，不需要 @ObservedObject/@StateObject）。
    // sheet 每次拉起都会重建本视图，vm 从 nil 重新 make，天然是一通"新电话"。
    @State private var vm: CallViewModel?
    @State private var showComparison = false

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    CallStageView(vm: vm)
                } else {
                    // make() 在 onAppear 才执行，首帧会短暂看到这里；给个占位避免空白闪屏
                    ProgressView("正在接入通话…")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 挂断 = 停一切 + 关页面。与 onDisappear 的 shutdown 重复调用无害
                    Button("挂断") {
                        vm?.shutdown()
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showComparison = true } label: {
                        Image(systemName: "chart.bar.xaxis")   // 对比模式入口
                    }
                }
            }
        }
        .onAppear {
            if vm == nil {
                // 与聊天页共用同一份 Pipeline 与 Key：语音里的"她"和打字的是同一个人设与记忆
                vm = .make(pipeline: app.pipeline, settings: app.settings)
            }
        }
        .onDisappear {
            vm?.shutdown()
        }
        .sheet(isPresented: $showComparison) {
            CallComparisonView(apiKey: app.settings.apiKey, baseURL: app.settings.baseURL)
        }
    }
}

// MARK: - 通话主界面
//
// 用普通 let 属性接 vm 即可：@Observable 的属性读取在 body 里被自动追踪，
// vm 的任何可观察属性变化都会让本视图重算 body（这是 Observation 宏的机制，
// 不需要包一层 @ObservedObject）。

struct CallStageView: View {
    let vm: CallViewModel

    var body: some View {
        VStack(spacing: 16) {
            statusIndicator

            // 语音路径切换：运行时可切，下一句就用新路径（切换不重启通话）
            routePicker

            subtitleArea

            callButton

            if let note = vm.degradationNote {
                // 云端合成失败自动切本地时的提示（仅提示，不阻塞通话）
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Text(metricsLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let message = vm.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    // MARK: 状态指示圆圈

    private var statusIndicator: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: statusIcon)
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                )
                // 收音中轻轻呼吸（放大缩小），其他状态静止
                .scaleEffect(vm.isRecording ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                           value: vm.isRecording)

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var statusColor: Color {
        switch vm.phase {
        case .idle: return .blue
        case .preparing: return .gray
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .green
        case .interrupted: return .yellow
        case .error: return .red
        }
    }

    private var statusIcon: String {
        switch vm.phase {
        case .idle: return "waveform"
        case .preparing: return "circle.dashed"
        case .listening: return "mic.fill"
        case .thinking: return "hourglass"
        case .speaking: return "speaker.wave.2.fill"
        case .interrupted: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        switch vm.phase {
        case .idle: return "通话未开始"
        case .preparing: return "正在接通…"
        case .listening: return "在听，说吧…"
        case .thinking: return "想想怎么回你…"
        case .speaking: return "她正在说…"
        case .interrupted: return "好的，你说…"
        case .error(let message): return message   // 启动失败（权限/音频会话）直接亮在这里
        }
    }

    // MARK: 语音路径切换

    private var routePicker: some View {
        // vm.route 是 private(set)：外部不能直接赋值，所以用自定义 Binding
        // 经 vm.updateRoute() 改（顺便清降级提示 + 立刻重试云端，见 VM 注释）
        Picker("语音路径", selection: Binding(
            get: { vm.route },
            set: { vm.updateRoute($0) })) {
            ForEach(TTSRoute.allCases) { route in
                Text(route.displayName).tag(route)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: 字幕区（她的回复 + 你的实时字幕）

    private var subtitleArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !vm.replyText.isEmpty {
                        Text("她：\(vm.replyText)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Text(vm.liveTranscript.isEmpty
                         ? "点击开始与 AI 对话"
                         : "我：\(vm.liveTranscript)")
                        .font(.body)
                        .foregroundStyle(vm.liveTranscript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(vm.liveTranscript.isEmpty ? Color.clear : Color.accentColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        // 旧版漏了这行：scrollTo 找不到锚点，自动滚动其实从没生效过
                        .id("live")
                }
                .padding()
            }
            .frame(maxHeight: 300)
            .onChange(of: vm.liveTranscript) { _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
            .onChange(of: vm.replyText) { _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
    }

    // MARK: 开始 / 结束按钮

    private var callButton: some View {
        Button(action: { vm.toggleRecording() }) {
            Text(isCallActive ? "结束通话" : "开始通话")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(isCallActive ? Color.red : Color.blue, in: Capsule())
        }
        // 她正在想/正在说时按钮锁定：此时点"结束"与打断逻辑纠缠不清，干脆禁掉。
        // 想改成"说话时也能挂断"→ 删掉 .disabled 并把 toggleRecording 换成 shutdown
        .disabled(vm.phase.isBusy)
    }

    /// 通话是否进行中。与 toggleRecording 的语义对齐：
    /// 只有 idle 和 error 算"没在通话"（error 态点按钮会重新开始）。
    private var isCallActive: Bool {
        if case .error = vm.phase { return false }
        return vm.phase != .idle
    }

    // MARK: 延迟指标

    /// 一行显示本轮三个关键延迟；本地路径没有"TTS 首包"概念，天然显示 —。
    /// 想加别的数字（如总耗时 totalMs）照着拼就行
    private var metricsLine: String {
        "LLM 首字 \(ms(vm.lastMetrics?.llmTTFTMs)) · " +
        "TTS 首包 \(ms(vm.lastMetrics?.ttsFirstPacketMs)) · " +
        "端到端首音 \(ms(vm.lastMetrics?.e2eFirstAudioMs))"
    }

    private func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))ms"
    }
}
