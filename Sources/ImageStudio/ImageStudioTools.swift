import Foundation

// MARK: - 生图工具（对应桌面端 index.js 注册的 image_generate / image_library）
//
// 模型通过 AgentTool 协议调用；图片生成完成后：
//   · 记录写入 ImageStudioStore.history（生成记录页可见）
//   · record 登记进 generatedLog，ChatView 在本轮回复后取出来贴到气泡上
// 返回给模型的文本沿用桌面端 renderGenerate 的要点：编号 / 参考 / 关键词 / 说明，
// 并提醒「不用复述画面、想改图把编号放进 extra_images」。

/// 生成一张图片并直接展示给用户
struct ImageGenerateTool: AgentTool {
    let store: ImageStudioStore

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "image_generate",
            description: "生成一张图片并直接展示给用户。按画面描述和关键词（情境 / 神态 / 动作 / 镜头 / 光线），把本地参考库里选中的人物 / 服饰 / 场景 / 道具参考图一起交给生图模型：参考图只保证长相和设计一致，姿势表情构图由文字决定。何时调用见系统提示里的「生图」说明。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("这张图的画面描述：谁在哪里、正在做什么、和周围的互动、构图与情绪重点。人物长相与服饰设计由参考图提供，不必重复；神态 / 动作 / 镜头 / 光线优先用下面的关键词参数，也可以直接写在这里。"),
                    ]),
                    "situation": .object([
                        "type": .string("string"),
                        "description": .string("情境关键词（如 在家休息、睡前、外出、工作学习），会自动带上对应的场景、服饰和光线。按角色此刻在哪、在做什么来选。"),
                    ]),
                    "expression": .object([
                        "type": .string("string"),
                        "description": .string("神态关键词（如 开心、害羞、困倦、委屈），按角色此刻的心情选；也可以直接写一句具体神态。"),
                    ]),
                    "pose": .object([
                        "type": .string("string"),
                        "description": .string("动作关键词（如 抱膝坐、趴着、托腮、伸懒腰），也可以直接写具体动作。"),
                    ]),
                    "shot": .object([
                        "type": .string("string"),
                        "description": .string("镜头关键词（如 自拍、近景、全身、俯视、第一人称）。"),
                    ]),
                    "light": .object([
                        "type": .string("string"),
                        "description": .string("光线关键词（如 午后暖阳、夜晚台灯、黄昏逆光）；不填时用情境的默认光线。"),
                    ]),
                    "characters": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("人物库条目（id 或名字），可多个。"),
                    ]),
                    "outfits": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("服饰库条目（id 或名字）。不填时沿用她此刻日程里的穿着（那段写了穿搭的话），否则按情境 / 场景 / 人物的默认服饰。想让她换别的衣服就在这里写明。"),
                    ]),
                    "scene": .object([
                        "type": .string("string"),
                        "description": .string("场景库条目（id 或名字），只能一个。"),
                    ]),
                    "props": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("道具库条目（id 或名字），可多个。"),
                    ]),
                    "extra_images": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("可选：要在其基础上修改的图（之前生成的图片编号 img-…），会作为第一张参考图。"),
                    ]),
                    "aspect": .object([
                        "type": .string("string"),
                        "description": .string("画幅比例，如 1:1、3:4、4:3、9:16、16:9；不填用默认。"),
                    ]),
                    "caption": .object([
                        "type": .string("string"),
                        "description": .string("可选：显示在图下面的一句配图说明。"),
                    ]),
                    "user_requested": .object([
                        "type": .string("boolean"),
                        "description": .string("用户本轮明确要求出图时为 true（不受主动发图间隔限制）。"),
                    ]),
                ]),
                "required": .array([.string("prompt")]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        guard !Task.isCancelled else { return "{\"error\": \"已取消\"}" }
        let args = Self.parseArguments(argumentsJSON)
        do {
            let record = try await store.generate(args, source: "tool")
            return Self.successText(record)
        } catch is CancellationError {
            return "{\"error\": \"已取消\"}"
        } catch let error as StudioError {
            return "{\"error\": \(Self.jsonString(error.message))}"
        } catch {
            if Task.isCancelled { return "{\"error\": \"已取消\"}" }
            return "{\"error\": \(Self.jsonString(error.localizedDescription))}"
        }
    }

    /// 宽容解析模型给的参数（可能不完全合规）
    static func parseArguments(_ argumentsJSON: String) -> StudioGenerateArgs {
        var args = StudioGenerateArgs()
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return args
        }
        func str(_ key: String) -> String { (obj[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        func list(_ key: String) -> [String] {
            if let arr = obj[key] as? [String] { return arr }
            if let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                // 有些模型会把数组写成逗号分隔字符串
                return s.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return []
        }
        args.prompt = str("prompt")
        args.situation = str("situation")
        args.expression = str("expression")
        args.pose = str("pose")
        args.shot = str("shot")
        args.light = str("light")
        args.characters = Array(list("characters").prefix(12))
        args.outfits = Array(list("outfits").prefix(12))
        args.scene = str("scene")
        args.props = Array(list("props").prefix(12))
        args.extraImages = Array(list("extra_images").prefix(4))
        args.aspect = str("aspect")
        args.caption = String(str("caption").prefix(300))
        args.userRequested = (obj["user_requested"] as? Bool) ?? false
        return args
    }

    /// 给模型的文字结果（要点沿用桌面端 renderGenerate）
    static func successText(_ record: ImageRecord) -> String {
        var lines: [String] = []
        let seconds = Double(record.ms) / 1000
        var head = "已生成图片 \(record.id)（\(record.model)"
        if !record.size.isEmpty { head += " · \(record.size)" }
        head += String(format: " · 用时 %.0f 秒）", seconds)
        head += "，已经显示在对话里给用户看了。"
        lines.append(head)
        if let file = record.files.first { lines.append("文件：\(file)") }
        let labels = ["characters": "人物", "outfits": "服饰", "scenes": "场景", "props": "道具"]
        if !record.refs.isEmpty {
            let parts = record.refs.map { ref in
                ref.kind == "extra"
                    ? (ref.name ?? "参考图")
                    : "\((labels[ref.category ?? ""] ?? "") + "「\(ref.name ?? "")」" + ((ref.count ?? 1) > 1 ? "×\(ref.count ?? 1)" : ""))"
            }
            lines.append("用到的参考：\(parts.joined(separator: "、"))")
        }
        if !record.keywords.isEmpty {
            let kwLabels = ["situation": "情境", "expression": "神态", "pose": "动作", "shot": "镜头", "light": "光线"]
            let parts = record.keywords.sorted { $0.key < $1.key }
                .map { "\(kwLabels[$0.key] ?? $0.key)「\($0.value)」" }
            lines.append("关键词：\(parts.joined(separator: "、"))")
        }
        if !record.notes.isEmpty { lines.append("说明：\(record.notes.joined(separator: "；"))") }
        if !record.unresolved.isEmpty {
            lines.append("参考库里没找到：\(record.unresolved.joined(separator: "、"))（已只按文字描述画）")
        }
        lines.append("不用再向用户复述画面；想基于这张继续改，把图片编号放进 extra_images。")
        return lines.joined(separator: "\n")
    }

    static func jsonString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

/// 查询本地生图参考库
struct ImageLibraryTool: AgentTool {
    let store: ImageStudioStore

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "image_library",
            description: "查询本地生图参考库（人物 / 服饰 / 场景 / 道具）：按关键词搜，或按 id 看某个条目的完整信息（人设、外观描述）。只在系统提示里的目录不够用时才需要。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "category": .object([
                        "type": .string("string"),
                        "enum": .array(StudioCategory.allCases.map { .string($0.rawValue) }),
                        "description": .string("只查某一个库：characters / outfits / scenes / props。"),
                    ]),
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("关键词，匹配名字、别名、标签、描述；留空列出全部。"),
                    ]),
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("查看某个条目的完整信息（含人设、外观描述）。"),
                    ]),
                ]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        var category: String?
        var query: String?
        var id: String?
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            category = obj["category"] as? String
            query = obj["query"] as? String
            id = obj["id"] as? String
        }
        return await MainActor.run {
            store.libraryQueryText(category: category, query: query, id: id)
        }
    }
}
