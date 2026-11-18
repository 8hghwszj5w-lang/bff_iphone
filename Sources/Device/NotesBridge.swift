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

        let box = ResultBox()
        let csQuery = CSSearchQuery(
            queryString: queryString,
            attributes: ["title", "contentDescription", "lastUsedDate"])

        csQuery.foundItemsHandler = { items in
            for item in items.prefix(limit) {
                let title = item.attributeSet.title ?? ""
                let snippet = item.attributeSet.contentDescription ?? ""
                if title.isEmpty && snippet.isEmpty { continue }
                box.append(NoteHit(id: item.uniqueIdentifier,
                                   title: title.isEmpty ? "(无标题)" : title,
                                   snippet: snippet,
                                   lastUsed: item.attributeSet.lastUsedDate))
            }
        }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            csQuery.completionHandler = { error in
                guard !finished else { return }
                finished = true
                if let error {
                    cont.resume(throwing: QueryError(message: "Spotlight 查询失败：\(error.localizedDescription)"))
                } else {
                    cont.resume(returning: box.snapshot())
                }
            }
            box.installDrainTimer { finished = true }   // 超时兜底（见 ResultBox）
            csQuery.start()
        }
    }

    /// 跨回调收集结果的线程安全小盒子；带 3 秒超时兜底
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [NoteHit] = []
        private var drainTimer: Timer?

        func append(_ hit: NoteHit) {
            lock.lock(); hits.append(hit); lock.unlock()
        }

        func snapshot() -> [NoteHit] {
            lock.lock(); defer { lock.unlock() }
            drainTimer?.invalidate()
            drainTimer = nil
            return hits
        }

        func installDrainTimer(_ onTimeout: @escaping () -> Void) {
            lock.lock()
            let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                self.lock.lock()
                let shouldFinish = self.hits.isEmpty
                self.lock.unlock()
                if shouldFinish { onTimeout() }
            }
            RunLoop.main.add(timer, forMode: .default)
            drainTimer = timer
            lock.unlock()
        }
    }
}
