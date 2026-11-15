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
@MainActor
final class AppState: ObservableObject {
    var settings: SettingsStore
    var memory: MemoryStore
    var persona: PersonaStore
    var pipeline: Pipeline
    var usage: UsageStore
    var chatBackground = ChatBackgroundStore()
    private var storeSubscriptions = Set<AnyCancellable>()

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.persona = PersonaStore()
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.memory = MemoryStore(directory: docs.appendingPathComponent("memory", isDirectory: true))
        self.usage = UsageStore(directory: docs)
        let search = WebSearchTool()
        let client = DeepSeekClient(settings: settings)
        self.pipeline = Pipeline(client: client, memory: memory,
                                 persona: persona, tools: [search],
                                 settings: settings, usage: usage)
        // EnvironmentObject 不会自动观察嵌套 ObservableObject。
        // 只转发 store 变更；流式文本仍局限在 ChatView 的本地状态。
        for publisher in [settings.objectWillChange, memory.objectWillChange,
                          persona.objectWillChange, usage.objectWillChange,
                          chatBackground.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &storeSubscriptions)
        }
    }
}
