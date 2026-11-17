import Foundation

// MARK: - 工具（Function Calling）：模型可以主动调用的能力
//
// ┌─ 怎么给"她"加一个新工具（比如查快递、控制智能家居）────────────┐
// │ 1. 在本文件仿照 WebSearchTool 写一个 struct，实现 AgentTool：      │
// │      definition  → 告诉模型"我是什么、什么时候该调我、要什么参数"  │
// │      run         → 真正干活，返回 JSON 字符串（出错也返回 JSON，   │
// │                    让模型自己决定怎么跟用户解释）                  │
// │ 2. 在 FenShenApp.init 里把实例加进 tools 数组                      │
// │ 3. 完成。Pipeline 会自动把 definition 声明给模型，                  │
// │    模型决定调用时经 DeepSeekClient.ask 的循环回调到 run             │
// │ description 写得越清楚，模型触发越准；参数 schema 用 JSONValue 拼   │
// └────────────────────────────────────────────────────────────────┘

/// 工具协议：模型可以调用的能力（对应原项目 src/tools/）
protocol AgentTool {
    /// 声明给模型的"说明书"：名字 + 什么时候用 + 参数 JSON Schema
    var definition: ToolDefinition { get }
    /// 真正执行。argumentsJSON 是模型给的参数（可能不完全合规，做好容错）
    func run(argumentsJSON: String) async -> String
}

/// 工具注册表：模型通过名字调用
/// 注意：App 实际走的是 Pipeline 注入的 tools 数组，这个全局注册表是备用通道
enum ToolRegistry {
    private static var tools: [String: AgentTool] = [:]

    static func register(_ tool: AgentTool) { tools[tool.definition.function.name] = tool }

    static func definitions() -> [ToolDefinition] { tools.values.map(\.definition) }

    static func run(name: String, argumentsJSON: String) async -> String {
        guard !Task.isCancelled else { return "{\"error\": \"已取消\"}" }
        guard let tool = tools[name] else {
            return "{\"error\": \(WebSearchTool.jsonString("unknown tool \(name)"))}"
        }
        return await tool.run(argumentsJSON: argumentsJSON)
    }
}

// MARK: - 联网搜索（默认 DuckDuckGo 免费无 key，对应原项目 websearch.js 的 bing 通道思路）

struct WebSearchTool: AgentTool {
    var session: URLSession = .shared

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "web_search",
            description: "搜索互联网获取最新信息。当用户询问时事、天气、价格、最新动态等需要联网的问题时调用。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"),
                                      "description": .string("搜索关键词")])
                ]),
                "required": .array([.string("query")])
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        guard !Task.isCancelled else { return "{\"error\": \"已取消\"}" }
        let query: String
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let q = obj["query"] as? String {
            query = q
        } else {
            return "{\"error\": \"参数需要 {\\\"query\\\": \\\"关键词\\\"}\"}"
        }

        // DuckDuckGo HTML 版，免 key。失败时返回错误让模型改口。
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = Self.searchURL(query: query) else {
            return "{\"error\": \"bad query\"}"
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: req)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return "{\"error\": \"搜索请求失败（HTTP \(status)）\"}"
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            let results = parseResults(from: html, limit: 5)
            if results.isEmpty { return "{\"results\": [], \"note\": \"没有搜到结果\"}" }
            let arr = results.map { r in
                "{\"title\": \(Self.jsonString(r.title)), \"snippet\": \(Self.jsonString(r.snippet)), \"url\": \(Self.jsonString(r.url))}"
            }.joined(separator: ",")
            return "{\"results\": [\(arr)]}"
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return "{\"error\": \"已取消\"}"
            }
            return "{\"error\": \(Self.jsonString("搜索失败: \(error.localizedDescription)"))}"
        }
    }

    static func searchURL(query: String) -> URL? {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        // URLQueryItem 不转义 +，但表单式搜索服务会把裸 + 当成空格。
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    struct Result { var title: String; var snippet: String; var url: String }

    // 固定且有界的表达式只编译一次，避免每条结果重复编译。
    private static let titlePattern = try? NSRegularExpression(pattern: "class=\"result__a\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
    private static let snippetPattern = try? NSRegularExpression(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
    private static let linkPattern = try? NSRegularExpression(pattern: "<a\\b(?=[^>]*class=\"[^\"]*\\bresult__a\\b[^\"]*\")[^>]*href=\"([^\"]+)\"", options: [.dotMatchesLineSeparators])

    /// 轻量 HTML 解析（不引第三方库）
    func parseResults(from html: String, limit: Int) -> [Result] {
        guard limit > 0 else { return [] }
        var out: [Result] = []
        var segments = html.components(separatedBy: "class=\"result__body\"")
        segments.removeFirst()
        for seg in segments.prefix(limit + 2) {
            let title = firstMatch(Self.titlePattern, in: seg)
            let snippet = firstMatch(Self.snippetPattern, in: seg)
            // 只取结果标题链接；支持 DDG 的 //duckduckgo.com/l/ 跳转及直接链接。
            let href = firstMatch(Self.linkPattern, in: seg)
                .replacingOccurrences(of: "&amp;", with: "&")
            guard !title.isEmpty else { continue }
            let absolute = href.hasPrefix("//") ? "https:" + href : href
            guard let components = URLComponents(string: absolute),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), components.host?.isEmpty == false else { continue }
            let realURL: String
            if ["duckduckgo.com", "www.duckduckgo.com"].contains(components.host?.lowercased() ?? ""),
               components.path == "/l/" {
                realURL = components.queryItems?.first(where: { $0.name == "uddg" })?.value ?? absolute
            } else {
                realURL = absolute
            }
            guard let target = URLComponents(string: realURL),
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
                  target.host?.isEmpty == false else { continue }
            out.append(Result(title: decode(title), snippet: decode(snippet), url: realURL))
            if out.count >= limit { break }
        }
        return out
    }

    private func firstMatch(_ pattern: NSRegularExpression?, in text: String) -> String {
        guard let re = pattern else { return "" }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return "" }
        return ns.substring(with: m.range(at: 1))
    }

    private func decode(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&apos;": "'"]
        for (k, v) in entities { r = r.replacingOccurrences(of: k, with: v) }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func jsonString(_ s: String) -> String {
        // 编码字符串本身而不是 [s]，否则 title/snippet/url 会错误地变成数组。
        guard let data = try? JSONEncoder().encode(s) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
