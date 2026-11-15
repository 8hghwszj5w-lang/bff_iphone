import Foundation
import Combine

// MARK: - OpenAI 兼容的消息类型（DeepSeek API 同构）

struct ChatMessage: Codable, Equatable {
    var role: String            // system / user / assistant / tool
    var content: String
    var toolCalls: [ToolCall]?
    var toolCallID: String?

    static func system(_ c: String) -> ChatMessage { .init(role: "system", content: c) }
    static func user(_ c: String) -> ChatMessage { .init(role: "user", content: c) }
    static func assistant(_ c: String) -> ChatMessage { .init(role: "assistant", content: c) }
    static func tool(result: String, for id: String) -> ChatMessage {
        .init(role: "tool", content: result, toolCallID: id)
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content.isEmpty ? " " : content, forKey: .content)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }

    init(role: String, content: String, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role; self.content = content
        self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
    }
}

struct ToolCall: Codable, Equatable {
    struct Function: Codable, Equatable {
        var name: String
        // API 可能返回非严格 JSON 字符串参数，按字符串收下再解析
        var arguments: String
    }
    var id: String
    var type: String
    var function: Function
}

struct ToolDefinition: Codable {
    struct FunctionDef: Codable {
        var name: String
        var description: String
        var parameters: JSONValue
    }
    var type = "function"
    var function: FunctionDef
}

/// 极简 JSON 值（只用于工具参数 schema）
enum JSONValue: Codable {
    case string(String), bool(Bool), double(Double), array([JSONValue]), object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .double(let d): try c.encode(d)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        self = .string(try c.decode(String.self))
    }
}

// MARK: - DeepSeek 客户端

struct ToolLoopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class DeepSeekClient: ObservableObject {
    struct Usage { var promptTokens = 0; var completionTokens = 0 }

    private let settings: SettingsStore
    private let session: URLSession
    /// 最多执行三轮工具，之后仅允许一次不带工具的总结请求。
    private let maxToolRounds = 3

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    /// 不自动重试：已发出的文本、工具副作用和 API 费用都无法安全回滚。
    func ask(messages: [ChatMessage], tools: [ToolDefinition],
             toolRunner: @escaping (String, String) async -> String,
             onDelta: ((String) -> Void)? = nil) async throws -> (String, Usage) {
        var convo = messages
        var totalUsage = Usage()

        for round in 0...maxToolRounds {
            try Task.checkCancellation()
            let availableTools = round < maxToolRounds ? tools : []
            let (text, toolCalls, usage) = try await chatOnce(convo, tools: availableTools, onDelta: onDelta)
            totalUsage.promptTokens += usage.promptTokens
            totalUsage.completionTokens += usage.completionTokens
            try Task.checkCancellation()
            guard !toolCalls.isEmpty else { return (text, totalUsage) }
            guard !availableTools.isEmpty else {
                throw ToolLoopError(message: "API 在禁用工具时仍返回工具调用，已停止以避免额外请求")
            }

            let allowedNames = Set(availableTools.map { $0.function.name })
            guard toolCalls.allSatisfy({ allowedNames.contains($0.function.name) }) else {
                throw ToolLoopError(message: "API 请求了本轮未声明的工具，已停止执行")
            }
            convo.append(ChatMessage(role: "assistant", content: text, toolCalls: toolCalls))
            for call in toolCalls {
                try Task.checkCancellation()
                let result = await toolRunner(call.function.name, call.function.arguments)
                try Task.checkCancellation()
                convo.append(.tool(result: result, for: call.id))
            }
        }
        throw ToolLoopError(message: "工具调用轮数已达上限")
    }

    /// 直接编码 Codable 消息和 schema，避免工具逐个 encode → decode → encode。
    private struct RequestBody: Encodable {
        struct StreamOptions: Encodable { let include_usage = true }
        let model: String
        let messages: [ChatMessage]
        let stream = true
        let temperature: Double
        let stream_options = StreamOptions()
        let tools: [ToolDefinition]?
    }

    static func completionURL(baseURL: String) throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ToolLoopError(message: "Base URL 无效：请填写不带账号、查询参数或片段的 HTTP(S) 地址")
        }
        // 保留自定义服务的路径前缀，去除末尾斜杠，避免 /v1//chat/completions。
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        components.percentEncodedPath += "/chat/completions"
        guard let url = components.url else {
            throw ToolLoopError(message: "Base URL 无效")
        }
        return url
    }

    func makeRequest(messages: [ChatMessage], tools: [ToolDefinition]) throws -> URLRequest {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolLoopError(message: "还没有填 API Key，请到「设置」里填写 DeepSeek API Key")
        }
        var req = URLRequest(url: try Self.completionURL(baseURL: settings.baseURL))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(RequestBody(
            model: settings.model, messages: messages, temperature: settings.temperature,
            tools: tools.isEmpty ? nil : tools))
        return req
    }

    private func chatOnce(_ messages: [ChatMessage], tools: [ToolDefinition],
                          onDelta: ((String) -> Void)? = nil)
        async throws -> (String, [ToolCall], Usage) {
        try Task.checkCancellation()
        let req = try makeRequest(messages: messages, tools: tools)
        let (bytes, response) = try await session.bytes(for: req)
        // DONE、错误或取消时都关闭尚未读完的响应，不让连接继续在后台消耗资源。
        let requestTask = bytes.task
        defer { requestTask.cancel() }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            throw ToolLoopError(message: "API 请求失败（HTTP \(http?.statusCode ?? -1)）")
        }

        return try await withTaskCancellationHandler {
            var stream = StreamAccumulator()
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let piece = try stream.consume(line: line) { onDelta?(piece) }
                if stream.isDone { break }
            }
            try Task.checkCancellation()
            return try stream.finish()
        } onCancel: {
            requestTask.cancel()
        }
    }

    /// 与网络分离，便于用固定 SSE 样本测试分片、错误和截断；不重放已输出的文本。
    struct StreamAccumulator {
        private(set) var isDone = false
        private var sawChoice = false
        private var finishReason: String?
        private var text = ""
        private var usage = Usage()
        private var calls: [Int: ToolCall] = [:]

        mutating func consume(line: String) throws -> String? {
            guard !isDone, line.hasPrefix("data:") else { return nil }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { return nil }
            if payload == "[DONE]" { isDone = true; return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                throw ToolLoopError(message: "API 流包含无效 JSON，已停止；不会自动重试")
            }
            if let error = obj["error"], !(error is NSNull) {
                let message = (error as? [String: Any])?["message"] as? String
                    ?? (error as? String) ?? "未知错误"
                throw ToolLoopError(message: "API 流错误：\(message)")
            }
            if let u = obj["usage"] as? [String: Any] {
                usage.promptTokens = u["prompt_tokens"] as? Int ?? usage.promptTokens
                usage.completionTokens = u["completion_tokens"] as? Int ?? usage.completionTokens
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let choice = choices.first else { return nil }
            sawChoice = true
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                if reason == "length" || reason == "content_filter" {
                    throw ToolLoopError(message: "API 回复未完整结束（\(reason)），已停止；不会自动重试")
                }
                finishReason = reason
            }
            guard let delta = choice["delta"] as? [String: Any] else { return nil }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    guard let index = tc["index"] as? Int, index >= 0 else {
                        throw ToolLoopError(message: "API 工具调用缺少有效 index")
                    }
                    var call = calls[index] ?? ToolCall(id: "", type: "function", function: .init(name: "", arguments: ""))
                    if let id = tc["id"] as? String, !id.isEmpty { call.id = id }
                    if let type = tc["type"] as? String, type != "function" {
                        throw ToolLoopError(message: "API 返回不支持的工具类型：\(type)")
                    }
                    if let fn = tc["function"] as? [String: Any] {
                        call.function.name += fn["name"] as? String ?? ""
                        call.function.arguments += fn["arguments"] as? String ?? ""
                    }
                    calls[index] = call
                }
            }
            guard let piece = delta["content"] as? String, !piece.isEmpty else { return nil }
            text += piece
            return piece
        }

        func finish() throws -> (String, [ToolCall], Usage) {
            // 部分兼容服务只发送 finish_reason 而没有 DONE，保留对此的兼容。
            guard sawChoice, isDone || finishReason != nil else {
                throw ToolLoopError(message: "API 流意外中断或未返回有效回复；不会自动重试")
            }
            let toolCalls = calls.keys.sorted().compactMap { calls[$0] }
            guard toolCalls.allSatisfy({ !$0.id.isEmpty && !$0.function.name.isEmpty }),
                  Set(toolCalls.map(\.id)).count == toolCalls.count else {
                throw ToolLoopError(message: "API 工具调用不完整或 ID 重复，已停止执行")
            }
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls, usage)
        }
    }
}
