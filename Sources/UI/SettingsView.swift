import SwiftUI
import PhotosUI

// MARK: - 设置页（API Key / 模型 / 行为开关）
//
// 这个文件装了设置主页面和全部 6 个子页面，结构如下（都在一个 NavigationStack 里推入）：
//   SettingsView            主页面：入口列表 + 联网开关 + 温度/窗口 + 清空记忆
//   ├ UsageView             用量信息：累计 token、估算花费、官方定价、近 7 天
//   ├ RechargeView          充值：拉起 Safari 收银台 + 微信/支付宝 App
//   ├ MemoryView            记忆管理：浏览窗口/改摘要/导出 JSON/分段清理
//   ├ ChatBackgroundView    聊天背景：选样式或照片（选照片进 ImageCropView 裁剪）
//   ├ PersonaEditor         人设：改她的性格（存 UserDefaults "persona.md"）
//   └ DeepSeekApiSettingsView  API Key/地址/模型 + 连通测试
// 加新子页面：写一个 View，主页面 body 里加 NavigationLink { 目标页 } 即可。
// 所有页面通过 @EnvironmentObject app 拿全局状态，改 Store 字段即时生效并持久化。

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        UsageView()
                    } label: {
                        HStack {
                            Label("用量信息", systemImage: "chart.bar.fill")
                            Spacer()
                            Text(app.usage.stats.totalTokens, format: .number)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    NavigationLink {
                        RechargeView()
                    } label: {
                        Label("充值", systemImage: "creditcard.fill")
                    }
                    NavigationLink {
                        MemoryView()
                    } label: {
                        HStack {
                            Label("记忆管理", systemImage: "brain")
                            Spacer()
                            Text("\(app.memory.record.entries.count) 条 · 摘要 \(app.memory.record.summary.isEmpty ? "无" : "有")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    NavigationLink {
                        PersonaEditor(persona: app.persona)
                    } label: {
                        HStack {
                            Label("人设", systemImage: "person.text.rectangle")
                            Spacer()
                            Text(app.persona.text == PersonaStore.defaultPersona ? "默认" : "已修改")
                                .font(.footnote)
                                .foregroundStyle(app.persona.text == PersonaStore.defaultPersona ? Color(.tertiaryLabel) : .green)
                        }
                    }
                    NavigationLink {
                        ChatBackgroundView()
                    } label: {
                        HStack {
                            Label("聊天背景", systemImage: "paintpalette")
                            Spacer()
                            Text(app.chatBackground.style.name)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        SchedulePageView(store: app.schedule)
                    } label: {
                        HStack {
                            Label("每日日程", systemImage: "calendar")
                            Spacer()
                            Text(app.schedule.currentDay.items.isEmpty
                                 ? "未设置" : "\(app.schedule.currentDay.items.count) 段")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                Section {
                    NavigationLink {
                        DeepSeekApiSettingsView()
                    } label: {
                        HStack {
                            Text("DeepSeek API")
                            Spacer()
                            Text(app.settings.apiKey.isEmpty ? "未配置" : "已配置")
                                .font(.footnote)
                                .foregroundStyle(app.settings.apiKey.isEmpty ? .orange : .green)
                        }
                    }
                    Toggle("允许她联网搜索", isOn: $app.settings.autoSearch)
                } header: {
                    Text("接口")
                } footer: {
                    Text("开启联网搜索后，她遇到时事类问题会自己调用 web_search 工具查完再答（DuckDuckGo，免费无 key）。")
                }
                Section("生成参数") {
                    HStack {
                        Text("温度")
                        Slider(value: $app.settings.temperature, in: 0...1.5, step: 0.05)
                        Text(String(format: "%.2f", app.settings.temperature))
                            .monospacedDigit().frame(width: 44)
                    }
                    Stepper("记忆逐字窗口：\(app.settings.maxHistory) 条",
                            value: $app.settings.maxHistory, in: 10...200, step: 10)
                }
                Section("危险操作") {
                    Button("清空记忆（人设保留）", role: .destructive) {
                        app.memory.reset()
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - DeepSeek API 子菜单

struct DeepSeekApiSettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var testResult: String?
    @State private var testState: TestState = .idle

    private enum TestState { case idle, testing, ok, failed }

    var body: some View {
        Form {
            Section {
                SecureField("API Key（sk-…）", text: $app.settings.apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Base URL", text: $app.settings.baseURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("模型", text: $app.settings.model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("API Key 只保存在本机（App 沙盒），不会上传。在 platform.deepseek.com 申请。")
            }
            Section("测试") {
                Button("发送一条测试消息") {
                    Task { await sendTestMessage() }
                }
                .disabled(app.settings.apiKey.isEmpty || testState == .testing)
                if testState == .testing {
                    HStack { ProgressView(); Text("正在请求…").font(.footnote).foregroundStyle(.secondary) }
                }
                if let lastResult = testResult {
                    Text(lastResult)
                        .font(.footnote)
                        .foregroundStyle(testState == .failed ? .orange : .secondary)
                }
            }
        }
        .navigationTitle("DeepSeek API")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendTestMessage() async {
        testState = .testing
        testResult = nil
        let client = DeepSeekClient(settings: app.settings)
        do {
            let (reply, usage) = try await client.ask(
                messages: [ChatMessage.user("用一句话打招呼，证明你在线")],
                tools: [], toolRunner: { _, _ in "" })
            testState = .ok
            testResult = "连通正常（\(usage.promptTokens + usage.completionTokens) tokens）：\(reply)"
        } catch {
            testState = .failed
            testResult = "失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 用量信息页（对应 src/core/usage.js 的报告能力）

struct UsageView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                row("总 token", app.usage.stats.totalTokens)
                row("提问 token", app.usage.stats.totalPromptTokens)
                row("回答 token", app.usage.stats.totalCompletionTokens)
                row("消息轮数", app.usage.stats.totalMessages)
                row("估算花费（上限）", "≈ \(String(format: "%.2f", estimatedCost)) 元")
                if let first = app.usage.stats.firstUsed {
                    row("首次使用", first.formatted(date: .abbreviated, time: .omitted))
                }
            } header: {
                Text("累计")
            } footer: {
                Text("花费按「高峰时段 + 缓存未命中」的最贵价估算，实际因缓存命中和空闲时段会更低。统计含每次回复的全部 token（联网搜索的多轮工具调用也计入）。")
            }
            Section {
                row("输入 · 缓存命中", "高峰 \(fmt(pricing.hit)) 元 / 空闲 \(fmt(pricing.hit / 2)) 元")
                row("输入 · 缓存未命中", "高峰 \(fmt(pricing.miss)) 元 / 空闲 \(fmt(pricing.miss / 2)) 元")
                row("输出", "高峰 \(fmt(pricing.out)) 元 / 空闲 \(fmt(pricing.out / 2)) 元")
                Button {
                    if let url = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("官方完整价格表")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.footnote)
                    }
                }
            } header: {
                Text("定价 · \(pricing.name)（每百万 tokens）")
            } footer: {
                Text("高峰时段：北京时间工作日 9:00–12:00、14:00–18:00（节假日除外），其余时段（含周末/节假日全天）为空闲半价。\(pricing.name == "deepseek-flash" ? "deepseek-v4-pro 约 4.5 倍价。" : "deepseek-flash 约为其 1/4.5 价。")本 App 的联网搜索和图片 OCR 都走免费本机通道，不产生这些费用。")
            }
            Section("最近 7 天") {
                ForEach(app.usage.recentDays(7), id: \.date) { day in
                    HStack {
                        Text(day.date == todayKey ? "今天" : day.date)
                            .font(.footnote)
                        Spacer()
                        Text("\(day.usage.messages) 轮 · \(day.usage.total) tokens")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(day.usage.total == 0 ? Color(.tertiaryLabel) : .primary)
                    }
                }
            }
            Section("危险操作") {
                Button("重置用量统计", role: .destructive) {
                    app.usage.reset()
                }
            }
        }
        .navigationTitle("用量信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var todayKey: String {
        UsageStore.dayKey(for: Date())
    }

    // MARK: 定价（来源：api-docs.deepseek.com/zh-cn/quick_start/pricing，2026-11 查询；单位：元 / 百万 tokens，高峰价）
    //
    // ⚠️ 官方调价后要手动更新这里（页面没做动态拉取，避免每次打开设置都发请求）：
    // hit = 输入·缓存命中   miss = 输入·缓存未命中   out = 输出（均为高峰价，空闲自动减半）
    // 官方页面还有一个"浏览器打开价格表"按钮（UsageView 里搜 pricing），核对用。
    private var pricing: (name: String, hit: Double, miss: Double, out: Double) {
        let pro = app.settings.model.lowercased().contains("v4-pro")
        return pro
            ? ("deepseek-v4-pro", 0.30, 9.0, 27.0)
            : ("deepseek-flash", 0.04, 2.0, 8.0)
    }

    /// 按「高峰 + 缓存未命中」最贵口径估算花费
    private var estimatedCost: Double {
        let s = app.usage.stats
        return Double(s.totalPromptTokens) / 1_000_000 * pricing.miss
             + Double(s.totalCompletionTokens) / 1_000_000 * pricing.out
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 充值页（余额在 DeepSeek 平台，充值走官方收银台；本页负责拉起 Safari / 微信 / 支付宝）

struct RechargeView: View {
    @EnvironmentObject private var app: AppState
    @State private var feedback: String?

    var body: some View {
        Form {
            Section {
                Text("余额由 DeepSeek 平台管理，App 只用你的 API Key 调用。充值在官方收银台完成，支持微信支付和支付宝。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    openURL("https://platform.deepseek.com/top_up")
                } label: {
                    Label("打开 DeepSeek 充值页", systemImage: "safari")
                }
                Button {
                    openURL("https://platform.deepseek.com")
                } label: {
                    Label("打开 DeepSeek 平台首页（备用）", systemImage: "globe")
                }
            } header: {
                Text("第 1 步 · 打开充值收银台")
            } footer: {
                Text("在收银台选择金额并点「微信支付 / 支付宝」，出现二维码后进行第 2 步扫码。")
            }
            Section {
                Button {
                    launchApp(scheme: "weixin://", name: "微信")
                } label: {
                    Label("拉起微信（扫码付款）", systemImage: "qrcode")
                        .foregroundStyle(.green)
                }
                Button {
                    launchApp(scheme: "alipays://", name: "支付宝")
                } label: {
                    Label("拉起支付宝（扫码付款）", systemImage: "qrcode")
                        .foregroundStyle(.blue)
                }
            } header: {
                Text("第 2 步 · 拉起 App 付款")
            } footer: {
                Text("iOS 无法替你直接付款：这里只负责把微信/支付宝拉到前台，用「扫一扫」完成上一步的二维码。")
            }
            if let feedback {
                Section {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("充值")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            feedback = "无效链接：\(urlString)"
            return
        }
        UIApplication.shared.open(url)
    }

    private func launchApp(scheme: String, name: String) {
        guard let url = URL(string: scheme) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            feedback = nil
        } else {
            feedback = "未检测到\(name)（可能没安装）。也可以在收银台页面直接选对应支付方式跳转。"
        }
    }
}

// MARK: - 记忆管理页（对应 src/store/memory.js 的运维面：浏览 / 编辑摘要 / 导出 / 分段清理）

struct MemoryView: View {
    @EnvironmentObject private var app: AppState
    @State private var summaryDraft = ""
    @State private var summaryDirty = false
    @State private var confirmClearAll = false

    var body: some View {
        Form {
            Section {
                row("窗口对话", "\(app.memory.record.entries.count) 条")
                row("长期摘要", app.memory.record.summary.isEmpty
                        ? "空"
                        : "\(app.memory.record.summary.split(separator: "\n").count) 行 / \(app.memory.record.summary.count) 字")
                if let oldest = app.memory.record.entries.first?.time {
                    row("窗口最早一条", oldest.formatted(date: .abbreviated, time: .shortened))
                }
                row("存储位置", app.memory.relativePath)
                if app.memory.fileByteSize > 0 {
                    row("文件大小", ByteCountFormatter().string(fromByteCount: app.memory.fileByteSize))
                }
            } header: {
                Text("概览")
            } footer: {
                Text("「窗口」是逐字保留的近期对话（超限自动压缩进摘要）；「摘要」是更早对话的长期记忆，两者都会喂给模型。")
            }

            Section("对话窗口（左滑删除单条）") {
                if app.memory.record.entries.isEmpty {
                    Text("还没有对话").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(app.memory.record.entries.enumerated().reversed()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.role == "user" ? "我" : "她")
                                    .font(.caption.bold())
                                    .foregroundStyle(entry.role == "user" ? .blue : .green)
                                Spacer()
                                Text(entry.time.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.content)
                                .font(.footnote)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { app.memory.removeEntriesInReverseOrder(at: $0) }
                }
            }

            Section("长期摘要（可直接编辑）") {
                TextEditor(text: $summaryDraft)
                    .font(.footnote)
                    .frame(minHeight: 120)
                    .onChange(of: summaryDraft) { newValue in
                        summaryDirty = newValue != app.memory.record.summary
                    }
                if summaryDirty {
                    Button("保存摘要修改") {
                        app.memory.updateSummary(summaryDraft)
                        summaryDirty = false
                    }
                }
            }

            Section("导出") {
                ShareLink("导出记忆 JSON（备份）", item: app.memory.exportText)
            }

            Section("危险操作") {
                Button("清空对话窗口（保留摘要）", role: .destructive) {
                    app.memory.clearEntries()
                }
                Button("清空长期摘要（保留窗口）", role: .destructive) {
                    app.memory.clearSummary()
                    summaryDraft = ""
                    summaryDirty = false
                }
                Button("清空全部记忆", role: .destructive) {
                    confirmClearAll = true
                }
                .confirmationDialog("确定清空全部记忆？窗口和摘要都会删除，无法恢复。",
                                    isPresented: $confirmClearAll, titleVisibility: .visible) {
                    Button("清空全部记忆", role: .destructive) {
                        app.memory.reset()
                        summaryDraft = ""
                        summaryDirty = false
                    }
                }
            }
        }
        .navigationTitle("记忆管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            summaryDraft = app.memory.record.summary
            summaryDirty = false
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 聊天背景设置页（纯色 / 渐变 / 相册自定义，即时生效）

struct ChatBackgroundView: View {
    @EnvironmentObject private var app: AppState
    @State private var pickedItem: PhotosPickerItem?
    @State private var cropTarget: UIImage?
    @State private var loadFailed = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var cropSheetBinding: Binding<Bool> {
        Binding(get: { cropTarget != nil }, set: { if !$0 { cropTarget = nil } })
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ChatBackgroundStyle.allCases) { style in
                    tile(style)
                }
            }
            .padding()

            VStack(spacing: 12) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("从相册选择背景照片", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)

                if app.chatBackground.hasOriginalImage {
                    Button {
                        if let original = app.chatBackground.loadOriginalImage() {
                            cropTarget = original
                        }
                    } label: {
                        Label("重新裁剪原图", systemImage: "crop")
                    }
                    .buttonStyle(.bordered)
                }

                if !app.chatBackground.customFile.isEmpty {
                    Button("移除自定义照片", role: .destructive) {
                        app.chatBackground.clearCustomImage()
                    }
                    .font(.footnote)
                }

                Text("选一张照片后进入裁剪：拖动调整位置，双指缩放，选好比例点「完成」即可应用。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if loadFailed {
                    Text("图片读取失败，换一张试试。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("聊天背景")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedItem) { item in
            guard let item else { return }
            loadFailed = false
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    app.chatBackground.saveOriginalImage(data)   // 保留原图供反复裁剪
                    cropTarget = image                            // 进入裁剪
                } else {
                    loadFailed = true
                }
                pickedItem = nil
            }
        }
        .sheet(isPresented: cropSheetBinding) {
            if let image = cropTarget {
                ImageCropView(image: image,
                              onCancel: { cropTarget = nil },
                              onDone: { cropped in
                                  app.chatBackground.saveCroppedImage(cropped)
                                  cropTarget = nil
                              })
            }
        }
    }

    @ViewBuilder
    private func tile(_ style: ChatBackgroundStyle) -> some View {
        let isSelected = app.chatBackground.style == style
        Button {
            app.chatBackground.select(style)
        } label: {
            VStack(spacing: 6) {
                preview(style)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(6)
                        }
                    }
                Text(style.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func preview(_ style: ChatBackgroundStyle) -> some View {
        // 缩略图里放两个小气泡，模拟真实聊天效果
        switch style {
        case .system: Color(.systemGroupedBackground)
        case .warm: Color(red: 0.96, green: 0.94, blue: 0.90)
        case .mint: Color(red: 0.90, green: 0.96, blue: 0.93)
        case .sakura: Color(red: 0.97, green: 0.92, blue: 0.94)
        case .aurora:
            LinearGradient(colors: [Color(red: 0.85, green: 0.89, blue: 1.00),
                                    Color(red: 0.93, green: 0.87, blue: 0.98),
                                    Color(red: 0.85, green: 0.97, blue: 0.96)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .night:
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22),
                                    Color(red: 0.05, green: 0.07, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
        case .custom:
            if app.chatBackground.customFile.isEmpty {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            } else {
                CustomChatBackground(fileName: app.chatBackground.customFile,
                                     revision: app.chatBackground.imageRevision)
            }
        }
    }
}

// MARK: - 人设管理页（对应 bridge/persona.md；设置 → 人设，导航推入）

struct PersonaEditor: View {
    @ObservedObject var persona: PersonaStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $persona.text)
            .font(.body)
            .padding(.horizontal, 8)
            .navigationTitle("人设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("恢复默认") { persona.reset() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { persona.save(); dismiss() }
                }
            }
    }
}
