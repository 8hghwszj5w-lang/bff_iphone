import SwiftUI

// MARK: - 每日日程管理页（对应桌面端插件「设置 → 每日日程」的精简版）
//
// 结构：今天/明天切换 → 时间线列表（此刻高亮）→ 添加一段 → 这一天的主题/心情。
// 所有编辑都走 ScheduleStore.adjust（同插件语义：截断/拆开被覆盖的时段，
// 手动编辑也会记入 changes）。想看注入给模型的真实文本 → 底部「注入预览」。

struct SchedulePageView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var store: ScheduleStore

    @State private var dayOffset = 0                       // 0=今天 1=明天
    @State private var newStart = Date()
    @State private var newEnd = Date()
    @State private var newActivity = ""
    @State private var newLocation = ""
    @State private var dayTypeName = ""
    @State private var title = ""
    @State private var mood = ""
    @State private var showInjectionPreview = false
    @State private var generateTypeID = "workday"
    @State private var generationHint = ""
    @State private var generating = false
    @State private var generationError: String?

    private var dateKey: String {
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        return ScheduleStore.dateKey(for: date)
    }
    private var day: DaySchedule {
        store.loadDay(dateKey: dateKey) ?? DaySchedule(date: dateKey)
    }

    var body: some View {
        // 一次渲染共享同一份日程；不要让每个分支都同步读盘、解码 JSON。
        let day = self.day
        let nowMinute = minutes(Date())
        Form {
            Section {
                Picker("哪一天", selection: $dayOffset) {
                    Text("今天").tag(0)
                    Text("明天").tag(1)
                }
                .pickerStyle(.segmented)
            }

            Section("这一天是什么日子") {
                TextField("类型（上班日 / 休息日…）", text: $dayTypeName)
                TextField("一句话概括今天", text: $title)
                TextField("心情（可选）", text: $mood)
                Button("保存主题") {
                    var day = self.day
                    day.dayTypeName = dayTypeName.isEmpty ? nil : dayTypeName
                    day.title = title.isEmpty ? nil : title
                    day.mood = mood.isEmpty ? nil : mood
                    store.saveDay(day)
                }
                .disabled(dayTypeName.isEmpty && title.isEmpty && mood.isEmpty)
            }

            Section {
                if day.items.isEmpty {
                    Text("这一天还没有安排").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(day.items.indices, id: \.self) { index in
                        timelineRow(item: day.items[index], nowMinute: nowMinute)
                    }
                    .onDelete { store.removeItems(dateKey: dateKey, offsets: $0) }
                }
            } header: {
                Text(dateKey)
            } footer: {
                Text("左滑删除一条；删除后的空档会自动补「在家休息 / 睡觉」。")
            }

            Section {
                DatePicker("开始", selection: $newStart, displayedComponents: .hourAndMinute)
                DatePicker("结束", selection: $newEnd, displayedComponents: .hourAndMinute)
                TextField("做什么（必填）", text: $newActivity)
                TextField("在哪（可选）", text: $newLocation)
                Button("添加到 \(dateKey)") {
                    // store.adjust 与桌面端一致：没有这一天的日程就拒绝（不凭空造一天）。
                    // 这里是用户主动给空的一天加东西，先建一天，再走覆盖逻辑。
                    if store.loadDay(dateKey: dateKey) == nil {
                        store.saveDay(DaySchedule(date: dateKey))
                    }
                    store.adjust(dateKey: dateKey,
                                 start: ScheduleItem.clock(minutes: minutes(newStart)),
                                 end: ScheduleItem.clock(minutes: minutes(newEnd)),
                                 activity: newActivity,
                                 note: "手动添加",
                                 location: newLocation.isEmpty ? nil : newLocation)
                    newActivity = ""
                    newLocation = ""
                }
                .disabled(newActivity.isEmpty || minutes(newEnd) <= minutes(newStart))
            } header: {
                Text("添加一段")
            } footer: {
                Text("添加走的是「覆盖时间段」逻辑：与现有安排重叠的部分会被截断或拆开。")
            }

            Section {
                Toggle("注入到对话（她此刻的生活背景）", isOn: $store.injectEnabled)
                Button("查看注入预览") { showInjectionPreview = true }
            } header: {
                Text("注入到对话")
            } footer: {
                Text("桌面端是按会话 /life 开关，iOS 单会话用一个总开关：关掉后每轮对话不再带上她的生活背景（适合干正事），日程本身和工具照常。预览 = 真正拼进 system 消息的文本。")
            }

            // 自动生成（对应桌面端 generate.js：加权挑类型 → LLM → JSON → 模板兜底）
            Section {
                Picker("类型", selection: $generateTypeID) {
                    ForEach(ScheduleDayType.defaults) { type in
                        Text(type.name).tag(type.id)
                    }
                }
                TextField("特别要求（可选，优先满足）", text: $generationHint)
                Button {
                    generateCurrentDay()
                } label: {
                    HStack {
                        if generating { ProgressView().padding(.trailing, 6) }
                        Text(generating ? "正在生成…" : "生成这一天的日程")
                    }
                }
                .disabled(generating)
                if let genError = generationError {
                    Text(genError).font(.footnote).foregroundStyle(.orange)
                }
                if let source = day.source {
                    HStack(spacing: 6) {
                        Image(systemName: source == "llm" ? "sparkles" : "doc.text")
                        Text(source == "llm" ? "由模型生成"
                             : source == "template" ? "来自兜底模板（模型当时不可用）" : source)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("自动生成（\(dayOffset == 0 ? "今天" : "明天")）")
            } footer: {
                Text("每晚 22:00 后打开 App 会自动生成明天的日程（加权挑类型 + 避开最近三天）；失败 20 分钟后重试。这里可以手动指定类型重新生成。")
            }
        }
        .navigationTitle("每日日程")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: syncDayFields)
        .onChange(of: dayOffset) { syncDayFields() }
        .sheet(isPresented: $showInjectionPreview) {
            NavigationStack {
                ScrollView {
                    let preview = store.injectionText(now: Date())
                    Text(preview.isEmpty ? "（注入已关闭：关掉「注入到对话」时不会拼进 system 消息）" : preview)
                        .font(.footnote.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("注入预览")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func timelineRow(item: ScheduleItem, nowMinute: Int) -> some View {
        let isCurrent = dayOffset == 0 && item.startMinute <= nowMinute && nowMinute < item.endMinute
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(item.start)–\(item.end)  \(item.activity)\(item.placeLabel)")
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isCurrent {
                Text("此刻")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
            }
        }
    }

    private func syncDayFields() {
        let day = store.loadDay(dateKey: dateKey)
        dayTypeName = day?.dayTypeName ?? (dayOffset == 0 ? "上班日" : "休息日")
        title = day?.title ?? ""
        mood = day?.mood ?? ""
    }

    private func minutes(_ date: Date) -> Int {
        Calendar.current.component(.hour, from: date) * 60
            + Calendar.current.component(.minute, from: date)
    }

    /// 手动「生成这一天的日程」：指定类型 + 特别要求，走同一套生成器（LLM 失败落模板）
    private func generateCurrentDay() {
        guard !generating else { return }
        generating = true
        generationError = nil
        let hint = generationHint.isEmpty ? nil : generationHint
        let typeID = generateTypeID
        let key = dateKey
        let persona = app.persona.text
        let wardrobe = store.wardrobeProvider?()   // 素材库快照：生成时给模型看衣柜 / 场景 / 物品 / 认识的人
        let client = DeepSeekClient(settings: app.settings)
        // 显式 do/catch：此前 Task 的闭包会 throw，错误被 Task 吞掉（编译器 #NoUseUnstructuredThrowingTask），
        // 一旦生成器在落模板前抛错，generating 永远停在 true，按钮会永久禁用。
        Task {
            do {
                let day = try await ScheduleGenerator.generateDay(
                    dateKey: key, persona: persona, characterName: "小深",
                    client: { prompt in
                        let (text, _) = try await client.ask(messages: [.user(prompt)],
                                                             tools: [],
                                                             toolRunner: { _, _ in "" })
                        return text
                    },
                    store: store, dayTypeId: typeID, hint: hint, wardrobe: wardrobe)
                // 失败落了模板时把错误透出给用户看（成功时 source==llm 无错误）
                if let genError = day.generationError {
                    generationError = "模型生成失败（\(genError)），已用「\(day.dayTypeName ?? "")」模板兜底。"
                }
                syncDayFields()
            } catch {
                generationError = "生成失败：\(error.localizedDescription)"
            }
            generating = false
        }
    }
}
