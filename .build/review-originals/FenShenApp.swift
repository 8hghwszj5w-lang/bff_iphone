import SwiftUI

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
    }
}
