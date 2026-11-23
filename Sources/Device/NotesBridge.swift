import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - 备忘录（只读，经系统 Spotlight 索引）
//
// 诚实边界：Apple 没有公开的备忘录读取 API（notes.sqlite 在沙盒外，
// SiriKit 不覆盖读取）。唯一公开通道是 CoreSpotlight 查询系统索引：
// 能拿到备忘录的标题与摘要片段（不是全文），且依赖设备已解锁。
// 查不到/为空时如实返回"没搜到"，工具描述里也写明这是"标题级别"的检索。
// 写入备忘录同样没有公开 API——想做"存到备忘录"要走分享面板，需要用户
// 手动确认，不属于工具能力范围（不做假装成功的假实现）。
//
// 超时：CSSearchQuery 在设备锁屏/索引异常时可能永远不回调 completionHandler。
// 这里用 OnceGate 保证续体只 resume 一次：正常完成、失败、3 秒超时三者先到先得，
// 超时返回已收集到的部分结果（通常为空），不再永久挂起。

final class SpotlightNotesBridge {   // 无共享 UI 状态，不需要主 actor
    // nonisolated(unsafe)：工具结构体在非隔离上下文构造；实例方法都在主 actor 上
    nonisolated(unsafe) static let shared = SpotlightNotesBridge()

    struct NoteHit: Identifiable, Equatable {
        let id: String                 // Spotlight 唯一 ID（可用来打开原备忘录）
        var title: String
        var snippet: String
        var lastUsed: Date?
    }

    private struct QueryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 按关键词搜备忘录标题/摘要。query 为空 = 列出最近使用的前几条。
    /// - Parameter limit: 最多返回条数（默认 10，上限 20）
    func search(_ query: String, limit: Int = 10) async throws -> [NoteHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // contentTypeIdentifier 限定为备忘录条目；关键词搜标题与摘要字段
        var queryString = "contentTypeIdentifier == \"com.apple.notes.note\""
        if !trimmed.isEmpty {
            let escaped = trimmed.replacingOccurrences(of: "\"", with: " ")
            queryString += " AND (titleDN CONTAINER[cd] \"\(escaped)\" OR contentDescription CONTAINER[cd] \"\(escaped)\")"
        }

        let box = ResultBox(limit: min(max(limit, 0), 20))
        let gate = OnceGate()
        // iOS 16 起 attributes: 版初始化器废弃，改用 queryContext（旧版等价于
        // fetchAttributes = 那几个字段）。queryContext 可空，这里显式带上要取的属性。
        let queryContext = CSSearchQueryContext()
        queryContext.fetchAttributes = ["title", "contentDescription", "lastUsedDate"]
        let csQuery = CSSearchQuery(queryString: queryString, queryContext: queryContext)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NoteHit], Error>) in
            let finish: (Result<[NoteHit], Error>) -> Void = { result in
                guard gate.claim() else { return }
                csQuery.cancel()
                continuation.resume(with: result)
            }
            csQuery.foundItemsHandler = { items in
                box.append(items)
            }
            csQuery.completionHandler = { error in
                if let error {
                    finish(.failure(QueryError(message: "Spotlight 查询失败：\(error.localizedDescription)")))
                } else {
                    finish(.success(box.snapshot()))
                }
            }
            // 3 秒兜底：不依赖 run loop（工具可能在任意执行器上跑），超时就返回部分结果
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                finish(.success(box.snapshot()))
            }
            csQuery.start()
        }
    }

    /// 跨回调收集结果的线程安全小盒子（去重 + 条数上限）
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var hits: [NoteHit] = []
        private var seen: Set<String> = []

        init(limit: Int) { self.limit = max(0, limit) }

        func append(_ items: [CSSearchableItem]) {
            lock.lock(); defer { lock.unlock() }
            for item in items where hits.count < limit {
                if seen.contains(item.uniqueIdentifier) { continue }
                let title = item.attributeSet.title ?? ""
                let snippet = item.attributeSet.contentDescription ?? ""
                if title.isEmpty && snippet.isEmpty { continue }
                seen.insert(item.uniqueIdentifier)
                hits.append(NoteHit(id: item.uniqueIdentifier,
                                    title: title.isEmpty ? "(无标题)" : title,
                                    snippet: snippet,
                                    lastUsed: item.attributeSet.lastUsedDate))
            }
        }

        func snapshot() -> [NoteHit] {
            lock.lock(); defer { lock.unlock() }
            return hits
        }
    }

    /// 续体只 resume 一次：完成/失败/超时三条路径先到先得
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
