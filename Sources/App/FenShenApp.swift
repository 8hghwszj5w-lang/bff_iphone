import SwiftUI
import Combine

@main
struct FenShenApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(appState)
        }
    }
}

/// 全局运行时：装配模型客户端、记忆、流水线（对应原项目 core-runtime.js 的角色）
///
/// ┌─ 数据流总览（改代码前先看这个）──────────────────────────────┐
/// │ ChatView(聊天界面)                                          │
/// │   └→ Pipeline.handle(用户文字+图片+文件)                     │
/// │        ├→ DeepSeekClient.uploadFile  文件先传 Files API      │
/// │        ├→ MemoryStore.append          消息落盘（可重启恢复）  │
/// │        ├→ DeepSeekClient.ask          调模型（SSE 流式）      │
/// │        │    └→ tools 里的 AgentTool   模型要联网时回调        │
/// │        └→ UsageStore.append           token 用量落盘         │
/// │ 所有 Store 的持久化文件都在 App 沙盒 Documents/ 下             │
/// └──────────────────────────────────────────────────────────┘
///
/// 想改什么去哪改：
/// · 模型名 / API Key / 温度      → Stores.swift 的 SettingsStore（设置页可改）
/// · 她的性格与说话方式           → Stores.swift 的 PersonaStore.defaultPersona
/// · 给模型加新能力（工具）       → Tools.swift 仿照 WebSearchTool 写一个，
///                                  再在下面 init 里加进 tools 数组
/// · 消息的处理流程               → Pipeline.swift 的 handle(_:)
/// · 聊天界面 / 输入栏            → UI/ChatView.swift
@MainActor
final class AppState: ObservableObject {
    // 全部声明为 var：SettingsView 里用 $app.settings.xxx 直接绑定子 Store 的字段，
    // Binding 的动态成员查找要求路径上每一段都可写。
    var settings: SettingsStore
    var memory: MemoryStore
    var persona: PersonaStore
    var pipeline: Pipeline
    var usage: UsageStore
    var schedule: ScheduleStore
    var studio: ImageStudioStore
    var chatBackground = ChatBackgroundStore()
    /// 主动消息插件（心跳 + 闹铃）：Store 管配置/挂起闹铃，Engine 管定时器/生成/通知
    var proactiveStore: ProactiveStore
    var proactive: ProactiveEngine
    // 持有 Combine 订阅，否则 sink 会被立即释放、UI 不再刷新
    private var storeSubscriptions = Set<AnyCancellable>()

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.persona = PersonaStore()
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.memory = MemoryStore(directory: docs.appendingPathComponent("memory", isDirectory: true))
        self.usage = UsageStore(directory: docs)
        // 每日日程（对应桌面端 dsh-daily-schedule）：一天一个 JSON，持久化在 Documents/schedule/
        let schedule = ScheduleStore(directory: docs.appendingPathComponent("schedule", isDirectory: true))
        self.schedule = schedule
        // 生图工作室（对应桌面端 dsh-image-studio）：参考库 / 关键词 / 生成记录都在 Documents/image-studio/
        let studio = ImageStudioStore(directory: docs.appendingPathComponent("image-studio", isDirectory: true),
                                      schedule: schedule)
        self.studio = studio
        // 主动消息插件：配置在 UserDefaults，挂起闹铃在 Documents/proactive/state.json
        let proactiveStore = ProactiveStore()
        self.proactiveStore = proactiveStore
        let search = WebSearchTool()
        let client = DeepSeekClient(settings: settings)
        // 主动消息引擎复用同一个 DeepSeekClient；ask 闭包返回 token 数给用量统计
        let proactive = ProactiveEngine(store: proactiveStore,
                                        settings: settings,
                                        persona: persona,
                                        memory: memory,
                                        schedule: schedule,
                                        usage: usage,
                                        characterName: schedule.characterName,
                                        ask: { messages in
                                            let (text, used) = try await client.ask(messages: messages,
                                                                                    tools: [],
                                                                                    toolRunner: { _, _ in "" })
                                            return (text, used.promptTokens, used.completionTokens)
                                        })
        self.proactive = proactive
        // tools 里的受「允许联网搜索」开关控制；alwaysTools 是常驻工具（日程记事 +
        // 本机日历/提醒/备忘录 + 主动消息 followup）；studioTools 受生图工作室开关控制。
        // 想加新工具：往对应数组里加
        self.pipeline = Pipeline(client: client, memory: memory,
                                 persona: persona, tools: [search],
                                 settings: settings, usage: usage,
                                 alwaysTools: [ScheduleAdjustTool(store: schedule),
                                               ScheduleViewTool(store: schedule),
                                               FollowupSetTool(store: proactiveStore),
                                               FollowupCancelTool(store: proactiveStore),
                                               CalendarReadTool(), CalendarCreateTool(),
                                               RemindersReadTool(), RemindersCreateTool(),
                                               NotesSearchTool()],
                                 schedule: schedule,
                                 studio: studio,
                                 studioTools: [ImageGenerateTool(store: studio),
                                               ImageLibraryTool(store: studio)],
                                 proactive: proactive)
        // EnvironmentObject 不会自动观察嵌套 ObservableObject。
        // 只转发 store 变更；流式文本仍局限在 ChatView 的本地状态。
        for publisher in [settings.objectWillChange, memory.objectWillChange,
                          persona.objectWillChange, usage.objectWillChange,
                          schedule.objectWillChange, studio.objectWillChange,
                          proactiveStore.objectWillChange, proactive.objectWillChange,
                          chatBackground.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &storeSubscriptions)
        }
        // 启动定时器 / 注册通知 category 与 BGAppRefresh（必须在启动期完成注册）
        proactive.applicationStarted()
    }

    /// 自动日程生成（对应桌面端 runner.js）：今天没日程立刻补；到 22:00 后补明天；
    /// 失败 20 分钟冷却。ChatView.onAppear 触发，幂等且不阻塞聊天。
    func autoGenerateSchedule() {
        let persona = persona.text
        let client = DeepSeekClient(settings: settings)
        Task {
            await ScheduleGenerator.autoFill(
                store: schedule, persona: persona, characterName: "小深",
                ask: { prompt in
                    let (text, _) = try await client.ask(messages: [.user(prompt)],
                                                         tools: [],
                                                         toolRunner: { _, _ in "" })
                    return text
                })
        }
    }
}
