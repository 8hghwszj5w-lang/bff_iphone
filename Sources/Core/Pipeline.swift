import Foundation

// MARK: - 聊天流水线（对应原项目 pipeline：收消息 → 记忆 → 模型(可调工具) → 清洗 → 发送 → 落盘）

@MainActor
final class Pipeline: ObservableObject {
    private let client: DeepSeekClient
    private let memory: MemoryStore
    private let persona: PersonaStore
    private let tools: [AgentTool]
    private let settings: SettingsStore
    private let usage: UsageStore

    init(client: DeepSeekClient, memory: MemoryStore, persona: PersonaStore,
         tools: [AgentTool], settings: SettingsStore, usage: UsageStore) {
        self.client = client; self.memory = memory; self.persona = persona
        self.tools = tools; self.settings = settings; self.usage = usage
    }

    /// 处理一条用户消息，流式返回回复文本。返回最终完整回复。
    func handle(userText: String, onDelta: @escaping (String) -> Void) async throws -> String {
        let defs = settings.autoSearch ? tools.map(\.definition) : []

        memory.append(role: "user", content: userText, maxHistory: settings.maxHistory)
        let context = memory.contextMessages(persona: persona.text)

        let (reply, usage) = try await client.ask(messages: context, tools: defs,
                                                  toolRunner: { name, args in
                                                      guard let tool = self.tools.first(where: { $0.definition.function.name == name }) else {
                                                          return "{\"error\": \"unknown tool\"}"
                                                      }
                                                      return await tool.run(argumentsJSON: args)
                                                  },
                                                  onDelta: onDelta)

        // 落盘用量（含工具调用轮次的所有 token）
        self.usage.append(promptTokens: usage.promptTokens,
                          completionTokens: usage.completionTokens)

        // 清洗：去掉模型偶尔冒出的多余前后缀
        let cleaned = clean(reply)
        memory.append(role: "assistant", content: cleaned, maxHistory: settings.maxHistory)
        return cleaned
    }

    private func clean(_ text: String) -> String {
        var t = text
        // 去掉 markdown 代码块围栏残留、连续空行
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
