import SwiftUI
import PhotosUI

// MARK: - 生图工作室设置页（对应桌面端插件设置页的移动端版）
//
// 结构（都从设置 → 生图工作室 进入，NavigationStack 推入）：
//   ImageStudioSettingsView   主页：开关 / 接口 / 发图时机 / 画面组合 / 各子页入口
//   ├ StudioLibraryListView          素材库（按类）：列表 / 从相册导入 / 删除 / 详情编辑
//   ├ StudioKeywordsView             关键词库：五组关键词增删改 + 恢复默认
//   ├ StudioHistoryView              生成记录：缩略图 / 删除 / 看大图
//   └ StudioQuickGenerateView        试画一张：不走参考库组合的纯文字快试
// 所有字段直接绑定 $app.studio.config.* / $app.studio.apiKey，didSet 即存。

struct ImageStudioSettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var testState: TestState = .idle
    @State private var testResult: String?

    private enum TestState { case idle, testing, ok, failed }

    var body: some View {
        Form {
            Section {
                Toggle("启用绘图", isOn: $app.studio.config.enabled)
            } footer: {
                Text("开启后她会拿到 image_generate 工具：聊天里她自己判断什么时候画一张（时机见下方「发图时机」），或你直接说「画一张」。图片保存在 App 沙盒 image-studio/outputs/。")
            }

            Section {
                TextField("Base URL（如 https://…/compatible-mode/v1）", text: $app.studio.config.api.baseURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("API Key", text: $app.studio.apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("生图模型（如 qwen-image-2.1-pro）", text: $app.studio.config.api.model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Picker("默认画幅", selection: $app.studio.config.api.defaultAspect) {
                    ForEach(StudioAPIConfig.aspects, id: \.self) { Text($0) }
                }
                Stepper("超时：\(app.studio.config.api.timeoutSec) 秒",
                        value: $app.studio.config.api.timeoutSec, in: 60...600, step: 60)
                Button("测试连接") { Task { await testConnection() } }
                    .disabled(app.studio.apiKey.isEmpty || app.studio.config.api.baseURL.isEmpty || testState == .testing)
                if testState == .testing {
                    HStack { ProgressView(); Text("正在请求…").font(.footnote).foregroundStyle(.secondary) }
                }
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(testState == .failed ? .orange : .secondary)
                }
            } header: {
                Text("接口（OpenAI 兼容 /v1/images）")
            } footer: {
                Text("任何 OpenAI 兼容的 /v1/images 接口都行；有参考图时先走 /images/edits，接口不支持会自动降级为纯文字生成（参考图不生效，会记在生成记录的说明里）。")
            }

            Section("发图时机") {
                Picker("策略", selection: Binding(
                    get: { app.studio.config.policy.mode },
                    set: { app.studio.config.policy.mode = $0 })) {
                    ForEach(StudioPolicyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper("主动发图冷却：\(app.studio.config.policy.cooldownMin) 分钟（0 = 不限）",
                        value: $app.studio.config.policy.cooldownMin, in: 0...30)
                TextField("补充发图规则（可选）", text: $app.studio.config.policy.rules, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section {
                TextField("全局画风（可选，如 日系二次元少女）", text: $app.studio.config.compose.stylePrompt)
                Stepper("参考图上限：\(app.studio.config.compose.maxRefs) 张",
                        value: $app.studio.config.compose.maxRefs, in: 1...8)
                Toggle("自动认出画面里提到的条目", isOn: $app.studio.config.compose.autoMatch)
                Toggle("沿用日程里她此刻的穿着", isOn: $app.studio.config.compose.followSchedule)
                Toggle("参考图只管长相（姿势表情按文字）", isOn: $app.studio.config.compose.identityOnly)
                TextField("日程的她对应人物库（留空自动认）", text: $app.studio.config.compose.imageCharacter)
            } header: {
                Text("画面组合")
            } footer: {
                Text("「沿用日程穿着」需要你在 每日日程 里给时间段写上穿搭（schedule_adjust 也能自己记）。")
            }

            Section {
                ForEach(StudioCategory.allCases) { category in
                    NavigationLink {
                        StudioLibraryListView(category: category)
                    } label: {
                        HStack {
                            Text(category.label)
                            Spacer()
                            Text("\(app.studio.libraryCounts[category] ?? 0) 项")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("素材库")
            } footer: {
                Text("每个人物 / 服饰 / 场景 / 道具是一个文件夹：几张参考图 + 一句外观描述。生图时参考图负责「长得像」，目录布局和桌面端 dsh-image-studio 一致，可以直接拷进沙盒复用。")
            }

            Section("关键词与记录") {
                NavigationLink {
                    StudioKeywordsView()
                } label: {
                    Label("关键词（情境 / 神态 / 动作 / 镜头 / 光线）", systemImage: "text.badge.star")
                }
                NavigationLink {
                    StudioHistoryView()
                } label: {
                    Label("生成记录", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    StudioQuickGenerateView()
                } label: {
                    Label("试画一张（不走参考库组合）", systemImage: "wand.and.stars")
                }
            }
        }
        .navigationTitle("生图工作室")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func testConnection() async {
        testState = .testing
        testResult = nil
        var config = app.studio.config
        config.api.apiKey = app.studio.apiKey
        do {
            let models = try await app.studio.client.listModels(config: config)
            testState = .ok
            testResult = models.isEmpty
                ? "连接正常，但没列出可用生图模型（可以直接填模型名试画）。"
                : "连接正常，可用模型：\(models.prefix(6).joined(separator: "、"))\(models.count > 6 ? " 等 \(models.count) 个" : "")"
        } catch {
            testState = .failed
            testResult = "失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 素材库（单类）：列表 / 导入 / 删除 / 详情

struct StudioLibraryListView: View {
    @EnvironmentObject private var app: AppState
    let category: StudioCategory
    @State private var showAdd = false

    var body: some View {
        List {
            let entries = app.studio.library[category] ?? []
            if entries.isEmpty {
                Text("还没有条目。点右上角 ＋ 从相册导入几张图，写一句外观描述。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                NavigationLink {
                    StudioEntryDetailView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                        if !entry.aliases.isEmpty {
                            Text("又名 \(entry.aliases.joined(separator: "、"))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(entry.images.count) 张参考图")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    let entry = app.studio.library[category]?[safe: index]
                    if let entry { app.studio.deleteEntry(entry) }
                }
            }
        }
        .navigationTitle("\(category.label)库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                StudioAddEntrySheet(category: category)
            }
        }
    }
}

/// 新建条目：从相册选 1–8 张参考图 + 填名字与描述
struct StudioAddEntrySheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let category: StudioCategory

    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var images: [Data] = []
    @State private var name = ""
    @State private var aliases = ""
    @State private var tags = ""
    @State private var description = ""
    @State private var persona = ""
    @State private var traits = ""
    @State private var defaultOutfit = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("参考图（1–8 张）") {
                PhotosPicker(selection: $pickedItems, maxSelectionCount: 8, matching: .images) {
                    Label("从相册选择", systemImage: "photo.on.rectangle.angled")
                }
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(images.indices, id: \.self) { index in
                                if let ui = UIImage(data: images[index]) {
                                    Image(uiImage: ui)
                                        .resizable().scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }
            Section("\(category.label)信息") {
                TextField("名字（必填）", text: $name)
                TextField("别名（逗号分隔，可选）", text: $aliases)
                TextField("标签（逗号分隔，可选）", text: $tags)
                TextField("默认服饰（可选）", text: $defaultOutfit)
            }
            Section("外观描述（会写进生图提示词）") {
                TextEditor(text: $description)
                    .frame(minHeight: 80)
                if category == .characters {
                    TextField("神态 / 小动作特点（可选）", text: $traits, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("人设（只给对话模型看，可选）", text: $persona, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        }
        .navigationTitle("新建\(category.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if busy {
                    ProgressView()
                } else {
                    Button("保存") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || images.isEmpty)
                }
            }
        }
        .onChange(of: pickedItems) { items in
            Task {
                var data: [Data] = []
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self), !d.isEmpty {
                        data.append(d)
                    }
                }
                images = Array(data.prefix(8))
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            _ = try app.studio.createEntry(
                category: category,
                name: name,
                aliases: aliases.split(whereSeparator: { ",，、".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                tags: tags.split(whereSeparator: { ",，、".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                persona: persona.trimmingCharacters(in: .whitespacesAndNewlines),
                traits: traits.trimmingCharacters(in: .whitespacesAndNewlines),
                defaultOutfit: defaultOutfit.trimmingCharacters(in: .whitespaces),
                images: images)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 条目详情：参考图网格 + 编辑元信息
struct StudioEntryDetailView: View {
    @EnvironmentObject private var app: AppState
    let entry: LibraryEntry
    @State private var description = ""
    @State private var persona = ""
    @State private var traits = ""
    @State private var defaultOutfit = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("参考图") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entry.images, id: \.self) { file in
                            StudioLibraryThumb(entry: entry, file: file)
                        }
                    }
                }
            }
            Section("信息") {
                row("id", entry.id)
                if !entry.aliases.isEmpty { row("别名", entry.aliases.joined(separator: "、")) }
                if !entry.tags.isEmpty { row("标签", entry.tags.joined(separator: "、")) }
            }
            Section("外观描述（写进生图提示词）") {
                TextEditor(text: $description).frame(minHeight: 80)
            }
            if entry.category == .characters {
                Section("人物专属") {
                    TextField("神态 / 小动作特点", text: $traits, axis: .vertical)
                    TextField("人设（只给对话模型看）", text: $persona, axis: .vertical)
                }
            }
            Section {
                TextField("默认服饰", text: $defaultOutfit)
            }
            Section {
                Button("保存修改") {
                    try? app.studio.updateEntry(entry.id, category: entry.category) { meta in
                        meta.description = description
                        meta.persona = persona
                        meta.traits = traits
                        meta.defaultOutfit = defaultOutfit
                        meta.name = entry.name
                    }
                    saved = true
                }
                if saved { Text("已保存").font(.footnote).foregroundStyle(.green) }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            description = entry.descriptionText
            persona = entry.persona
            traits = entry.traits
            defaultOutfit = entry.defaultOutfit
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }
}

/// 素材库缩略图（复用生成图缓存不合适——路径不同；单独小缓存）
struct StudioLibraryThumb: View {
    @EnvironmentObject private var app: AppState
    let entry: LibraryEntry
    let file: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.secondarySystemGroupedBackground).overlay(ProgressView())
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: "\(entry.category.rawValue)/\(entry.id)/\(file)") {
            let url = app.studio.entryImageURL(entry, file: file)
            let loaded = await Task.detached(priority: .utility) {
                AttachmentExtractor.image(from: url, maxPixelSize: 256)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

// MARK: - 关键词库

struct StudioKeywordsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        List {
            ForEach(StudioPresetGroup.allCases) { group in
                NavigationLink {
                    StudioKeywordGroupView(group: group)
                } label: {
                    HStack {
                        Text(group.label)
                        Spacer()
                        Text("\(app.studio.presets.items(for: group).count) 条")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("关键词")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StudioKeywordGroupView: View {
    @EnvironmentObject private var app: AppState
    let group: StudioPresetGroup
    @State private var showAdd = false
    @State private var editing: StudioPresetItem?

    private var items: [StudioPresetItem] {
        app.studio.presets.items(for: group)
    }

    /// 情境条目的默认搭配摘要（抽成方法：行内写 ViewBuilder 会拖慢类型检查）
    private func extrasLine(_ item: StudioPresetItem) -> String? {
        guard group == .situation else { return nil }
        var extras: [String] = []
        if let scene = item.scene, !scene.isEmpty { extras.append("场景 \(scene)") }
        if let outfit = item.outfit, !outfit.isEmpty { extras.append("服饰 \(outfit)") }
        if let light = item.light, !light.isEmpty { extras.append("光线 \(light)") }
        return extras.isEmpty ? nil : extras.joined(separator: " · ")
    }

    var body: some View {
        List {
            ForEach(items, id: \.name) { item in
                Button { editing = item } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                        if !item.aliases.isEmpty {
                            Text("别名：\(item.aliases.joined(separator: "、"))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if !item.prompt.isEmpty {
                            Text(item.prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let line = extrasLine(item) {
                            Text(line).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .onDelete { offsets in
                var next = items
                next.remove(atOffsets: offsets)
                app.studio.presets.setItems(next, for: group)
            }
        }
        .navigationTitle("\(group.label)（\(group.rawValue)）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAdd = true } label: { Label("添加关键词", systemImage: "plus") }
                    Button(role: .destructive) { app.studio.resetPresetGroup(group) } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { StudioKeywordEditSheet(group: group, initial: nil) }
        }
        .sheet(item: $editing) { item in
            NavigationStack { StudioKeywordEditSheet(group: group, initial: item) }
        }
    }
}

/// 新增 / 编辑一条关键词
struct StudioKeywordEditSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let group: StudioPresetGroup
    let initial: StudioPresetItem?

    @State private var name = ""
    @State private var aliases = ""
    @State private var prompt = ""
    @State private var scene = ""
    @State private var outfit = ""
    @State private var light = ""

    var body: some View {
        Form {
            Section {
                TextField("名字（必填，模型填的就是它）", text: $name)
                TextField("别名（逗号分隔，可选）", text: $aliases)
            }
            Section("展开描写（替换成具体画面描述写进提示词）") {
                TextEditor(text: $prompt).frame(minHeight: 80)
            }
            if group == .situation {
                Section("默认搭配（库里没有就只按文字）") {
                    TextField("场景（可选）", text: $scene)
                    TextField("服饰（可选）", text: $outfit)
                    TextField("光线（可选）", text: $light)
                }
            }
        }
        .navigationTitle(initial == nil ? "添加\(group.label)" : "编辑\(group.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if let initial {
                name = initial.name
                aliases = initial.aliases.joined(separator: "、")
                prompt = initial.prompt
                scene = initial.scene ?? ""
                outfit = initial.outfit ?? ""
                light = initial.light ?? ""
            }
        }
    }

    private func save() {
        var item = StudioPresetItem(
            name: name.trimmingCharacters(in: .whitespaces),
            aliases: aliases.split(whereSeparator: { ",，、".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        if group == .situation {
            item.scene = scene.trimmingCharacters(in: .whitespaces)
            item.outfit = outfit.trimmingCharacters(in: .whitespaces)
            item.light = light.trimmingCharacters(in: .whitespaces)
        }
        var items = app.studio.presets.items(for: group)
        if let initial, let index = items.firstIndex(where: { $0.name == initial.name }) {
            items[index] = item
        } else {
            items.append(item)
        }
        app.studio.presets.setItems(items, for: group)
        dismiss()
    }
}

// MARK: - 生成记录

struct StudioHistoryView: View {
    @EnvironmentObject private var app: AppState
    @State private var viewerPath: String?

    var body: some View {
        List {
            let records = app.studio.recentRecords
            if records.isEmpty {
                Text("还没有生成记录。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(records.filter { $0.status != "deleted" }) { record in
                Button {
                    if let rel = record.files.first {
                        viewerPath = rel
                    }
                } label: {
                    HStack(spacing: 10) {
                        Group {
                            if let rel = record.files.first {
                                StudioBubbleImage(relativePath: rel)
                                    .frame(width: 52, height: 52)
                                    .clipped()
                            } else {
                                Image(systemName: record.status == "failed" ? "xmark.circle" : "photo")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, height: 52)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(record.id)
                                    .font(.caption.monospaced())
                                Spacer()
                                statusLabel(record)
                            }
                            Text(record.prompt)
                                .font(.footnote)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            Text(record.at.formatted(date: .abbreviated, time: .shortened)
                                 + " · \(record.aspect.isEmpty ? "默认比例" : record.aspect)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                let visible = app.studio.recentRecords.filter { $0.status != "deleted" }
                for index in offsets {
                    if let record = visible[safe: index] {
                        app.studio.deleteRecord(record.id)
                    }
                }
            }
        }
        .navigationTitle("生成记录")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: Binding(get: { viewerPath != nil },
                                              set: { if !$0 { viewerPath = nil } })) {
            if let path = viewerPath {
                StudioFullScreenImageView(relativePath: path)
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ record: ImageRecord) -> some View {
        switch record.status {
        case "done":
            Text("完成").font(.caption2).foregroundStyle(.green)
        case "running":
            Text("进行中").font(.caption2).foregroundStyle(.orange)
        case "failed":
            Text("失败").font(.caption2).foregroundStyle(.red)
        case "cancelled":
            Text("已取消").font(.caption2).foregroundStyle(.secondary)
        default:
            Text(record.status).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 试画一张（设置页发起，不走参考库组合）

struct StudioQuickGenerateView: View {
    @EnvironmentObject private var app: AppState
    @State private var prompt = ""
    @State private var aspect = ""
    @State private var busy = false
    @State private var record: ImageRecord?
    @State private var error: String?

    var body: some View {
        Form {
            Section("画面描述") {
                TextEditor(text: $prompt)
                    .frame(minHeight: 90)
                Picker("画幅", selection: $aspect) {
                    Text("默认").tag("")
                    ForEach(StudioAPIConfig.aspects, id: \.self) { Text($0).tag($0) }
                }
                Button {
                    Task { await generate() }
                } label: {
                    if busy {
                        HStack { ProgressView(); Text("生成中，生图一般要几十秒…") }
                    } else {
                        Label("生成", systemImage: "wand.and.stars")
                    }
                }
                .disabled(busy || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let record {
                Section("结果（\(record.status == "done" ? "完成" : record.status)）") {
                    if let rel = record.files.first {
                        StudioBubbleImage(relativePath: rel)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if !record.notes.isEmpty {
                        Text("说明：" + record.notes.joined(separator: "；"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !record.unresolved.isEmpty {
                        Text("参考库里没找到：" + record.unresolved.joined(separator: "、"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !record.error.isEmpty {
                        Text(record.error).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("试画一张")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func generate() async {
        busy = true
        error = nil
        record = nil
        var args = StudioGenerateArgs()
        args.prompt = prompt
        args.aspect = aspect
        args.userRequested = true
        do {
            record = try await app.studio.generate(args, source: "ui")
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

// MARK: - 小工具

extension Array {
    /// 越界安全下标（列表删除偏移换算用）
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
