import Foundation
import Combine

// MARK: - OpenAI 兼容的消息类型（DeepSeek API 同构）
//
// 这个文件 = App 的"电话机"：所有跟 DeepSeek 服务器的对话都从这里出去。
// · 对话：POST <baseURL>/chat/completions，SSE 流式（见 chatOnce / StreamAccumulator）
// · 文件：POST <baseURL去/v1>/files，multipart 上传拿 file_id（见 uploadFile）
// · 图片：不走单独接口，作为消息里的 image_url 块随对话发出
// 错误策略：所有失败都抛 ToolLoopError 且不自动重试——流式已经吐出去的字
// 没法收回，重试会导致用户看到重复内容+双倍计费。
// 官方文档：api-docs.deepseek.com/zh-cn（对话/图像理解/Files API 三个页面）

struct ChatMessage: Codable, Equatable {
    var role: String            // system / user / assistant / tool
    var content: String         // 纯文本内容；带 parts 时作为块数组里的文本块
    var toolCalls: [ToolCall]?  // 模型主动要求调工具时由 API 填入（发送时为 nil）
    var toolCallID: String?     // role == "tool" 时必填，对应上面 toolCalls 的 id
    /// 非空时 content 按官方文档编码为块数组（图像 / Files API 文件引用）
    /// 只有 user 消息会用；设置见 Pipeline.handle 第 4 步
    var parts: [ContentPart]?

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
        if let parts, !parts.isEmpty {
            // OpenAI 兼容多模态格式：content 为块数组，文本块在最前
            var blocks: [ContentPart] = []
            if !content.isEmpty { blocks.append(.text(content)) }
            blocks.append(contentsOf: parts)
            try c.encode(blocks, forKey: .content)
        } else {
            try c.encode(content.isEmpty ? " " : content, forKey: .content)
        }
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }

    init(role: String, content: String, toolCalls: [ToolCall]? = nil,
         toolCallID: String? = nil, parts: [ContentPart]? = nil) {
        self.role = role; self.content = content
        self.toolCalls = toolCalls; self.toolCallID = toolCallID
        self.parts = parts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        if let blocks = try? c.decode([ContentPart].self, forKey: .content) {
            parts = blocks
            content = blocks.compactMap {
                if case .text(let t) = $0 { return t }
                return nil
            }.joined(separator: "\n")
        } else {
            parts = nil
            content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        }
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
    }
}

/// 对话请求的内容块（DeepSeek 图像理解 / Files API 文档格式）
enum ContentPart: Codable, Equatable, Sendable {
    case text(String)
    case imageDataURL(String)   // data:image/jpeg;base64,... 或 https URL
    case fileID(String)         // Files API file-api-...

    enum Keys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
        case fileID = "file_id"
        case url
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .imageDataURL(let url):
            try c.encode("image_url", forKey: .type)
            var nested = c.nestedContainer(keyedBy: Keys.self, forKey: .imageURL)
            try nested.encode(url, forKey: .url)
        case .fileID(let id):
            try c.encode("file", forKey: .type)
            try c.encode(id, forKey: .fileID)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "image_url":
            let nested = try c.nestedContainer(keyedBy: Keys.self, forKey: .imageURL)
            self = .imageDataURL(try nested.decode(String.self, forKey: .url))
        case "file":
            self = .fileID(try c.decode(String.self, forKey: .fileID))
        default:
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
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

/// DeepSeek 错误响应体：{"error": {"message": "…"}}
struct APIErrorMessage: Decodable {
    struct Payload: Decodable { let message: String }
    let error: Payload
}

@MainActor
final class DeepSeekClient: ObservableObject {
    struct Usage { var promptTokens = 0; var completionTokens = 0 }

    private let settings: SettingsStore
    private let session: URLSession
    private let uploadDirectory: URL
    /// 最多执行三轮工具，之后仅允许一次不带工具的总结请求。
    /// 调大更聪明但更贵更慢；想改搜不到就死心 vs 搜出错误答案的平衡点就改这里
    private let maxToolRounds = 3

    init(settings: SettingsStore, session: URLSession = .shared,
         uploadDirectory: URL = FileManager.default.temporaryDirectory) {
        self.settings = settings
        // session / 临时目录可注入：测试只使用离线 protocol 和独立目录。
        self.session = session
        self.uploadDirectory = uploadDirectory
    }

    /// 带工具调用循环的完整提问（App 的主入口，Pipeline 每条消息调一次）。
    ///
    /// 循环逻辑（对应原项目 tool-loop.js）：
    ///   发消息 → API 返回纯文本 → 直接返回（最常见路径）
    ///   发消息 → API 返回 tool_calls → 本地执行 → 结果作为 tool 消息续上 → 再问
    ///   ……最多 maxToolRounds 轮；用尽仍未拿到纯文本 → 抛错（不无限烧钱）
    /// - toolRunner: 工具执行器，Pipeline 注入；签名是 (工具名, 参数JSON) → 结果JSON
    /// - onDelta:    流式增量回调（打字机效果），每个文本片段回调一次
    /// 不自动重试：已发出的文本、工具副作用和 API 费用都无法安全回滚。
    func ask(messages: [ChatMessage], tools: [ToolDefinition],
             toolRunner: @escaping (String, String) async -> String,
             onDelta: ((String) -> Void)? = nil) async throws -> (String, Usage) {
        var convo = messages          // 会话副本，工具轮次会往里追加消息
        var totalUsage = Usage()      // 所有轮次 token 累计（用量统计的数据源）

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
    /// 想加请求参数（如 top_p / max_tokens / response_format）：在这里加字段即可，
    /// Codable 会自动放进 JSON；可选参数用 let xxx: T? = nil 表达"不传"。
    private struct RequestBody: Encodable {
        struct StreamOptions: Encodable { let include_usage = true }
        let model: String
        let messages: [ChatMessage]
        let stream = true                          // SSE 流式，打字机效果靠它
        let temperature: Double                    // 越高越发散，设置页可调 0–1.5
        let stream_options = StreamOptions()       // 流式也要返回 usage（用量统计依赖）
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

    /// Files API 端点。官方根地址是 https://api.deepseek.com（/v1 是聊天兼容别名），
    /// 因此默认配置下的 …/v1 需要去掉，得到 https://api.deepseek.com/files。
    static func filesURL(baseURL: String) throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ToolLoopError(message: "Base URL 无效：请填写不带账号、查询参数或片段的 HTTP(S) 地址")
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath.hasSuffix("/v1") {
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast(3))
        }
        components.percentEncodedPath += "/files"
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

    /// Files API：multipart/form-data 上传，返回 file_id（形如 file-api-…）。
    /// purpose 取值见官方文档：图片/纯文本/表格/电子书 = user_data；
    /// PDF/Word/PPT 文字解析 = text_recognition（图文混排为 rich_layout_recognition）。
    /// 官方细节：purpose 字段必须在 file 字段之前，否则 PDF 等文档上传返回 400；
    /// 不传 expires_after 时文件永久有效（挂在账号下，可在官网 Files 页清理）。
    func uploadFile(data: Data, filename: String, purpose: String) async throws -> String {
        try await uploadFile(source: .data(data), filename: filename, purpose: purpose)
    }

    /// 文档直接传 URL，避免调用方先把整个文件读入内存。安全作用域在后台读取期间持有。
    func uploadFile(fileURL: URL, filename: String, purpose: String) async throws -> String {
        try await uploadFile(source: .file(fileURL), filename: filename, purpose: purpose)
    }

    private enum UploadSource: Sendable {
        case data(Data)
        case file(URL)
    }

    private func uploadFile(source: UploadSource, filename: String, purpose: String) async throws -> String {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolLoopError(message: "还没有填 API Key，请到「设置」里填写 DeepSeek API Key")
        }
        try Task.checkCancellation()
        let boundary = "FenShen-\(UUID().uuidString)"
        var req = URLRequest(url: try Self.filesURL(baseURL: settings.baseURL))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        // 文档：普通文件 10 分钟上传时限，给足超时余量
        req.timeoutInterval = 600

        let directory = uploadDirectory
        // detached 不继承 MainActor；Data 只共享原缓冲区，multipart 不再复制整份附件。
        let preparation = Task.detached(priority: .utility) {
            try Self.writeMultipart(source: source, filename: filename, purpose: purpose,
                                    boundary: boundary, directory: directory)
        }
        let bodyURL = try await withTaskCancellationHandler {
            // 即使父任务取消，也等后台写入退出/交还文件，避免清理与写入并发。
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Task.checkCancellation()
        let (respData, response) = try await session.upload(for: req, fromFile: bodyURL)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            let serverMessage = (try? JSONDecoder().decode(APIErrorMessage.self, from: respData))?.error.message
            throw ToolLoopError(message: serverMessage.map { "文件上传失败（HTTP \(http?.statusCode ?? -1)）：\($0)" }
                ?? "文件上传失败（HTTP \(http?.statusCode ?? -1)）")
        }
        struct UploadResponse: Decodable { let id: String }
        guard let decoded = try? JSONDecoder().decode(UploadResponse.self, from: respData),
              !decoded.id.isEmpty else {
            throw ToolLoopError(message: "文件上传响应缺少 file_id，已停止")
        }
        return decoded.id
    }

    /// 仅后台调用。最多保留一块文件数据；写入失败/取消清理半成品，成功后由上传者清理。
    nonisolated private static func writeMultipart(source: UploadSource, filename: String, purpose: String,
                                                   boundary: String, directory: URL) throws -> URL {
        try Task.checkCancellation()
        let fileURL = directory.appendingPathComponent("FenShen-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: fileURL) } }
        let output = try FileHandle(forWritingTo: fileURL)
        defer { try? output.close() }
        // 官方要求 purpose 字段在 file 字段之前，字段/CRLF 与原 Data 接口保持一致。
        let header = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n\(purpose)\r\n"
            + "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))
        let chunkSize = 64 * 1024
        switch source {
        case .data(let data):
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                let end = data.index(offset, offsetBy: min(chunkSize, data.distance(from: offset, to: data.endIndex)))
                try output.write(contentsOf: data[offset..<end])
                offset = end
            }
        case .file(let sourceURL):
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                // 每块结束即释放 Foundation 可能产生的 autoreleased 缓冲区。
                let hasChunk = try autoreleasepool {
                    guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                    try output.write(contentsOf: chunk)
                    return true
                }
                if !hasChunk { break }
            }
        }
        try Task.checkCancellation()
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()
        try Task.checkCancellation()
        complete = true
        return fileURL
    }

    private func chatOnce(_ messages: [ChatMessage], tools: [ToolDefinition],
                          onDelta: ((String) -> Void)? = nil)
        async throws -> (String, [ToolCall], Usage) {
        try Task.checkCancellation()
        let req = try makeRequest(messages: messages, tools: tools)
        // bytes(for:) 是 SSE 的关键：不把整个响应下载完才返回，而是边到边读
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
                    if let type = tc["type"] as? String, type != "function" {
                        throw ToolLoopError(message: "API 返回不支持的工具类型：\(type)")
                    }
                    let empty = ToolCall(id: "", type: "function", function: .init(name: "", arguments: ""))
                    // default 下标通过 _modify 原位追加，避免取副本后每片复制已累积的长参数。
                    if let id = tc["id"] as? String, !id.isEmpty { calls[index, default: empty].id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        calls[index, default: empty].function.name += fn["name"] as? String ?? ""
                        calls[index, default: empty].function.arguments += fn["arguments"] as? String ?? ""
                    }
                    // 空分片也保留 index，使 finish() 仍拒绝不完整的调用。
                    if calls[index] == nil { calls[index] = empty }
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
