import Foundation

// MARK: - 聊天流水线（对应原项目 pipeline：收消息 → 记忆 → 模型(可调工具) → 清洗 → 发送 → 落盘）

/// 用户本轮附带的一个文件（fileImporter 返回的安全作用域 URL）
struct UserFileAttachment {
    let name: String
    let localURL: URL
}

@MainActor
final class Pipeline: ObservableObject {
    private let client: DeepSeekClient
    private let memory: MemoryStore
    private let persona: PersonaStore
    private let tools: [AgentTool]
    /// 常驻工具（如日程记事）：不受「允许联网搜索」开关影响，永远声明给模型
    private let alwaysTools: [AgentTool]
    /// 生图工具（image_generate / image_library）：受生图工作室开关控制
    private let studioTools: [AgentTool]
    private let settings: SettingsStore
    private let usage: UsageStore
    /// 每日日程：每轮把"她此刻的生活背景"注入 system 消息
    private let schedule: ScheduleStore?
    /// 生图工作室：每轮把「生图说明 + 参考库目录」注入 system 消息；关闭时不声明工具
    private let studio: ImageStudioStore?
    /// 主动消息引擎：回合首尾通知它（对话期间压住心跳/闹铃；用户开口即视为闭环提前完成）
    private weak var proactive: ProactiveEngine?

    init(client: DeepSeekClient, memory: MemoryStore, persona: PersonaStore,
         tools: [AgentTool], settings: SettingsStore, usage: UsageStore,
         alwaysTools: [AgentTool] = [], schedule: ScheduleStore? = nil,
         studio: ImageStudioStore? = nil, studioTools: [AgentTool] = [],
         proactive: ProactiveEngine? = nil) {
        self.client = client; self.memory = memory; self.persona = persona
        self.tools = tools; self.alwaysTools = alwaysTools; self.studioTools = studioTools
        self.settings = settings; self.usage = usage; self.schedule = schedule
        self.studio = studio
        self.proactive = proactive
    }

    /// 处理一条用户消息，流式返回回复文本。返回最终完整回复。
    ///
    /// 一步一图（从上到下就是执行顺序）：
    ///  1. 模型能力检查      图片只支持 deepseek-flash，v4-pro 直接拒绝
    ///  2. 上传文件          按扩展名选 purpose → Files API 拿 file_id
    ///                       （不支持的类型 → 本地抽纯文本，塞进消息文字里）
    ///  3. 写记忆            存「轻量标记」，不存 base64/file_id（见下）
    ///  4. 组装上下文        system(人设+摘要) + 历史窗口；本轮消息替换为带块版本
    ///  5. 调模型            client.ask 内部处理工具调用循环（联网搜索）
    ///  6. 落用量 + 写回复   回复清洗后也进记忆
    ///
    /// 想改的点：
    /// · 想保存 file_id 让多轮都能引用同一文件 → 见第 3 步注释（要先给
    ///   MemoryRecord 加字段，并处理文件过期/删除后的引用失败）
    /// · 想改「不支持图片」的提示 → 第 1 步那段文案
    /// - images: JPEG/PNG 编码后的图片数据，按官方文档转 base64 内联 image_url 块
    /// - files:  文件引用，按类型走 Files API 上传（file_id 块）或本地文本兜底
    func handle(userText: String,
                images: [Data] = [],
                files: [UserFileAttachment] = [],
                onDelta: @escaping (String) -> Void) async throws -> String {
        // 回合首尾通知主动消息引擎：期间压住心跳/闹铃，用户开口同时取消挂起闹铃
        // （defer 保证抛错路径也能结束回合，让被压着的到点闹铃立刻补跑）
        await proactive?.beginUserTurn()
        defer { proactive?.endUserTurn() }
        try Task.checkCancellation()
        // 记下本轮开始时的生成计数：结束后从 studio 取这一轮新画的图
        let generationEpochBefore = studio?.generationEpoch ?? 0
        // 常驻工具（日程记事）始终声明；搜索工具受「允许联网搜索」开关控制；
        // 生图工具受生图工作室开关控制（关掉时连工具都不声明，模型不会白调）。
        let studioActive = studio?.config.enabled == true
        let allToolPool = tools + alwaysTools + (studioActive ? studioTools : [])
        let defs = (settings.autoSearch ? tools.map(\.definition) : [])
            + alwaysTools.map(\.definition)
            + (studioActive ? studioTools.map(\.definition) : [])

        // 图像理解仅 deepseek-flash 支持；提前给出明确指引而不是让 API 报错
        if !images.isEmpty, settings.model.lowercased().contains("v4-pro") {
            throw ToolLoopError(message: "当前模型 \(settings.model) 不支持图片输入，请到「设置 → DeepSeek API」把模型改为 deepseek-flash 后重试")
        }

        // 组装内容块：文件先上传，不支持的类型退回本地纯文本抽取
        var parts: [ContentPart] = []
        var fallbackTexts: [String] = []
        for file in files {
            let ext = (file.name as NSString).pathExtension.lowercased()
            if let purpose = AttachmentExtractor.uploadPurpose(ext: ext) {
                let fileID = try await client.uploadFile(fileURL: file.localURL,
                                                         filename: file.name, purpose: purpose)
                parts.append(.fileID(fileID))
            } else {
                // 兜底路径：zip/exe 等二进制没法给模型，本地抽文本塞进消息体
                // （zip 会在这里被 AttachmentError.binaryFile 拦下并提示用户）
                let extraction = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try AttachmentExtractor.fileText(from: file.localURL)
                }
                let text = try await withTaskCancellationHandler {
                    try await extraction.value
                } onCancel: { extraction.cancel() }
                try Task.checkCancellation()
                fallbackTexts.append("【文件「\(file.name)」内容如下】\n\(text)")
            }
        }
        // 图片转官方 data URL 格式（https://api-docs.deepseek.com/zh-cn/guides/vision）
        if !images.isEmpty {
            let encoding = Task.detached(priority: .userInitiated) {
                try images.map { imageData -> ContentPart in
                    try Task.checkCancellation()
                    return .imageDataURL("data:image/jpeg;base64," + imageData.base64EncodedString())
                }
            }
            parts += try await withTaskCancellationHandler {
                try await encoding.value
            } onCancel: { encoding.cancel() }
        }
        try Task.checkCancellation()

        // 记忆里存轻量标记（图片/文件的 file_id 不落盘，避免历史请求引用已过期资源）：
        // 这样重启后历史仍能看出"那轮带过图/文件"，但不会重复发送大体积数据。
        // 想让多轮引用同一文件：把 fileID 存进 MemoryRecord 并在 contextMessages
        // 里还原成 .fileID 块——注意官方 file 无 expiration 时永久有效，但要处理 404。
        var memoryText = userText
        if !fallbackTexts.isEmpty {
            memoryText = fallbackTexts.joined(separator: "\n\n") + (memoryText.isEmpty ? "" : "\n\n" + memoryText)
        }
        if !images.isEmpty {
            memoryText += (memoryText.isEmpty ? "" : "\n") + "［本轮附带图片 ×\(images.count)，直传给模型］"
        }
        for file in files where AttachmentExtractor.uploadPurpose(ext: (file.name as NSString).pathExtension.lowercased()) != nil {
            memoryText += (memoryText.isEmpty ? "" : "\n") + "［附带文件：\(file.name)，经 Files API 直传］"
        }

        memory.append(role: "user", content: memoryText, maxHistory: settings.maxHistory)
        // contextMessages 组出 system（人设 + 日程背景 + 生图说明 + 记忆摘要）+ 历史窗口；都是纯文本
        let scheduleBlock = schedule?.injectionText(now: Date()) ?? ""
        let studioBlock = studioActive ? (studio?.guideText() ?? "") : ""
        var context = memory.contextMessages(persona: persona.text,
                                             scheduleBlock: scheduleBlock,
                                             studioBlock: studioBlock)
        // 直传块只作用于本轮请求：最近一条用户消息替换为带块的版本。
        // （历史消息保持纯文本——base64 太大，file_id 已过期会报错）
        if !parts.isEmpty, let idx = context.lastIndex(where: { $0.role == "user" }) {
            context[idx].parts = parts
        }

        let (reply, usage) = try await client.ask(messages: context, tools: defs,
                                                  toolRunner: { name, args in
                                                      guard let tool = allToolPool.first(where: { $0.definition.function.name == name }) else {
                                                          return "{\"error\": \"unknown tool\"}"
                                                      }
                                                      return await tool.run(argumentsJSON: args)
                                                  },
                                                  onDelta: onDelta)

        // 落盘用量（含工具调用轮次的所有 token）→ 设置「用量信息」页显示的就是它
        self.usage.append(promptTokens: usage.promptTokens,
                          completionTokens: usage.completionTokens)

        // 清洗：去掉模型偶尔冒出的多余前后缀
        let cleaned = clean(reply)
        // 本轮她若调了 image_generate，把图记进这条 assistant 记忆：
        //   · entry.images 存 outputs/ 相对路径（重启后气泡还能显示）
        //   · 正文追加一句轻量标记，下一轮她还知道自己刚画过什么
        let generated = studio?.recordsSince(generationEpochBefore) ?? []
        let generatedImages = generated.filter(\.isDone).compactMap { $0.files.first }
        var memoryContent = cleaned
        if !generated.isEmpty {
            let marker = generated.map { record in
                record.isDone ? "［她刚画了一张图 \(record.id)，已经展示给用户］"
                              : "［她试着画一张图（\(record.id)），没画成］"
            }.joined(separator: "\n")
            memoryContent = (cleaned + "\n" + marker).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        memory.append(role: "assistant", content: memoryContent, maxHistory: settings.maxHistory,
                      images: generatedImages.isEmpty ? nil : generatedImages)
        return cleaned
    }

    /// 发送前最后一道清洗。想改她说话的"洁癖程度"改这里。
    private func clean(_ text: String) -> String {
        var t = text
        // 去掉 markdown 代码块围栏残留、连续空行
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
