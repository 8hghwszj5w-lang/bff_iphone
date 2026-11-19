import Foundation

// MARK: - 生图 API 客户端（移植桌面端 providers.js 的 openai-images 路径）
//
// OpenAI 兼容 images 接口：
//   无参考图 → POST {base}/v1/images/generations（JSON）
//   有参考图 → POST {base}/v1/images/edits（multipart，多张用 image[]）；
//              不少中转没实现 edits，请求失败时降级为纯文字生成并记一条 note（与桌面端一致）；
//              注意只有「请求失败」才降级，请求成功但响应异常要如实报错，避免重复扣费。
// 响应 data[] 里 b64_json 或 url 都认；url 需要下载（失败重试 3 次）。
// 65535 原生异步任务接口是桌面端专属，这里不实现。

struct ImageStudioClient: Sendable {
    var session: URLSession = .shared

    struct GeneratedImage: Sendable {
        var data: Data
        var ext: String
    }

    struct Outcome: Sendable {
        var images: [GeneratedImage]
        var model: String
        var size: String
        var notes: [String]
    }

    // MARK: 错误

    static let friendlyStatus: [Int: String] = [
        400: "参数有误",
        401: "API Key 无效或已过期",
        402: "余额不足或 Key 配额用尽",
        403: "没有权限（模型 / 分组不对，或被内容审核拦下）",
        404: "接口或任务不存在（检查 Base URL）",
        409: "同一请求还在处理中",
        413: "请求太大（参考图太多或太大）",
        429: "请求太频繁，被限流了",
        502: "上游暂时不可用",
        503: "队列繁忙或暂无可用渠道",
        524: "网关超时（国际线路别用同步接口）",
    ]

    /// 从响应体里提取一句人话错误（对应 providers.js readError）
    static func readError(status: Int, body: Data) -> StudioError {
        var message = ""
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let error = obj["error"]
            if let dict = error as? [String: Any], let m = dict["message"] as? String {
                message = m
            } else if let m = error as? String {
                message = m
            } else if let m = obj["message"] as? String {
                message = m
            }
        }
        if message.isEmpty {
            let text = String(decoding: body, as: UTF8.self)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            message = String(text.prefix(300))
        }
        let head = friendlyStatus[status].map { "\($0)（HTTP \(status)）" } ?? "HTTP \(status)"
        return StudioError(message: message.isEmpty ? head : "\(head)：\(message)")
    }

    /// OpenAI 兼容地址：补 /v1 后缀（对应 providers.js v1()）
    static func v1Base(_ base: String) throws -> String {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { throw StudioError(message: "还没填 Base URL（设置 → 生图工作室 → 接口）") }
        var cleaned = b
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned.hasSuffix("/v1") ? cleaned : "\(cleaned)/v1"
    }

    static func endpoint(_ base: String, _ path: String) throws -> URL {
        guard let url = URL(string: "\(base)\(path)") else {
            throw StudioError(message: "Base URL 无效：\(base)\(path)")
        }
        return url
    }

    /// 比例 → OpenAI 尺寸（对应 providers.js pixelSize）
    static func pixelSize(_ aspect: String) -> String? {
        if aspect.range(of: #"^\d{3,4}x\d{3,4}$"#, options: .regularExpression) != nil { return aspect }
        let parts = aspect.split(separator: ":")
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b > 0 else {
            return nil
        }
        let ratio = a / b
        if ratio > 1.15 { return "1536x1024" }
        if ratio < 0.87 { return "1024x1536" }
        return "1024x1024"
    }

    // MARK: 入口

    /// 一次生图。refURLs 为本地参考图路径；有参考图先试 edits，请求失败降级 generations。
    func generate(config: StudioConfig, prompt: String, refURLs: [URL], aspect: String) async throws -> Outcome {
        let base = try Self.v1Base(config.api.baseURL)
        guard !config.api.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StudioError(message: "还没填 API Key（设置 → 生图工作室 → 接口）")
        }
        let auth = "Bearer \(config.api.apiKey)"
        let size = Self.pixelSize(aspect)
        let timeout = TimeInterval(max(30, config.api.timeoutSec))

        var notes: [String] = []
        if !refURLs.isEmpty {
            var editsData: Data?
            do {
                // multipart 里要读整份参考图，放后台拼，不占主线程
                let preparation = Task.detached(priority: .userInitiated) {
                    try Self.editsMultipart(model: config.api.model, prompt: prompt,
                                            size: size, quality: config.api.quality,
                                            refURLs: refURLs)
                }
                let body = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                var req = URLRequest(url: try Self.endpoint(base, "/images/edits"))
                req.httpMethod = "POST"
                req.setValue("multipart/form-data; boundary=\(Self.multipartBoundary)", forHTTPHeaderField: "Content-Type")
                req.setValue(auth, forHTTPHeaderField: "Authorization")
                req.timeoutInterval = timeout
                req.httpBody = body
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    editsData = data
                } else {
                    let http = response as? HTTPURLResponse
                    let err = Self.readError(status: http?.statusCode ?? -1, body: data)
                    notes.append("参考图接口不可用（\(err.message)），已降级为纯文字生成——参考图未生效")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                notes.append("参考图接口调用失败（\(error.localizedDescription)），已降级为纯文字生成——参考图未生效")
            }
            if let editsData {
                // 请求已成功扣费：响应异常时如实报错，不要降级再付一次
                return try await Self.parseImages(editsData, fallbackModel: config.api.model, notes: notes)
            }
        }

        // 纯文字生成
        var payload: [String: Any] = ["model": config.api.model, "prompt": prompt, "n": 1]
        if let size { payload["size"] = size }
        if !config.api.quality.isEmpty { payload["quality"] = config.api.quality }
        var req = URLRequest(url: try Self.endpoint(base, "/images/generations"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw StudioError(message: "请求失败：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            throw Self.readError(status: http?.statusCode ?? -1, body: data)
        }
        return try await Self.parseImages(data, fallbackModel: config.api.model, notes: notes)
    }

    /// 拉取当前 Key 可用的生图模型（设置页「测试连接」用；对应 providers.js listModels）
    func listModels(config: StudioConfig) async throws -> [String] {
        let base = try Self.v1Base(config.api.baseURL)
        guard !config.api.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StudioError(message: "还没填 API Key（设置 → 生图工作室 → 接口）")
        }
        var req = URLRequest(url: try Self.endpoint(base, "/models"))
        req.setValue("Bearer \(config.api.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw StudioError(message: "连不上 \(base)：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            throw Self.readError(status: http?.statusCode ?? -1, body: data)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            return []
        }
        var ids: [String] = []
        for m in list {
            guard let id = m["id"] as? String else { continue }
            // capabilities 标注了 image 的直接收；没标注的按名字猜
            if let caps = m["capabilities"] as? [String] {
                if caps.contains("image") { ids.append(id) }
                continue
            }
            if id.range(of: #"(?i)image|dall|flux|seedream|banana|imagen|sd|kolors|grok-imagine"#,
                        options: .regularExpression) != nil {
                ids.append(id)
            }
        }
        return ids
    }

    // MARK: 内部

    private static let multipartBoundary = "FenShen-ImageStudio-\(UUID().uuidString)"

    /// /images/edits 的 multipart 请求体。参考图字段名：单张 image，多张 image[]（桌面端同款）。
    nonisolated static func editsMultipart(model: String, prompt: String, size: String?,
                                           quality: String, refURLs: [URL]) throws -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(multipartBoundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("model", model)
        field("prompt", prompt)
        field("n", "1")
        if let size { field("size", size) }
        if !quality.isEmpty { field("quality", quality) }
        let fieldName = refURLs.count > 1 ? "image[]" : "image"
        for (index, url) in refURLs.enumerated() {
            let data = try Data(contentsOf: url)
            let sniffed = studioSniffImage(data)
            let ext = !sniffed.isEmpty ? sniffed : (url.pathExtension.isEmpty ? ".png" : ".\(url.pathExtension)")
            body.append(Data("--\(multipartBoundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"ref\(index)\(ext)\"\r\n".utf8))
            body.append(Data("Content-Type: \(studioMime(of: ext))\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(multipartBoundary)--\r\n".utf8))
        return body
    }

    /// 解析 images 响应：b64_json 或 url（url 下载，重试 3 次）
    nonisolated static func parseImages(_ data: Data, fallbackModel: String, notes: [String]) async throws -> Outcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw StudioError(message: "接口返回里没有图片")
        }
        var buffers: [Data] = []
        for d in list {
            if let b64 = d["b64_json"] as? String, let decoded = Data(base64Encoded: b64) {
                buffers.append(decoded)
            } else if let url = d["url"] as? String, !url.isEmpty {
                buffers.append(try await download(url))
            }
        }
        if buffers.isEmpty { throw StudioError(message: "接口返回里没有图片") }
        let images = buffers.map { GeneratedImage(data: $0, ext: studioSniffImage($0).isEmpty ? ".png" : studioSniffImage($0)) }
        return Outcome(images: images, model: fallbackModel, size: "", notes: notes)
    }

    /// 下载生成的图片，失败重试 3 次（对应 providers.js download，去掉桌面代理提示）
    nonisolated static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw StudioError(message: "图片地址无效") }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 120
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let http = response as? HTTPURLResponse
                    throw StudioError(message: "HTTP \(http?.statusCode ?? -1)")
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(1_500_000_000 * Double(attempt + 1)))
                }
            }
        }
        throw StudioError(message: "图片已生成，但下载失败：\((lastError as? LocalizedError)?.errorDescription ?? lastError?.localizedDescription ?? "未知错误")")
    }
}
