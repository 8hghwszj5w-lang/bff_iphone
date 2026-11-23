import Foundation

// MARK: - 时间上下文：让模型感知"现在几点"与"过了多久"
//
// 两条通道（设计说明，改之前先看）：
// · 粗粒度（system 块）：日程注入里已有「现在：M月d日 …约 HH:MM」，半小时档。
//   故意不放精确分钟——system 是提示词前缀，每轮改它会把 DeepSeek 的
//   上下文缓存全部打掉（多花钱且变慢）。
// · 精确到分（本文件）：给每条用户消息加「［yyyy-MM-dd HH:mm 周X］」前缀，
//   随消息一起写进记忆窗口。模型在窗口里看到相邻两条的时间戳，就"看见"了
//   时间流逝；隔了多久会另外附 gap 文案（见 gapText）。
//
// 显示边界：戳只给模型看，不进气泡。历史恢复时 ChatView 用 stripStamp 去掉
// 前缀再渲染；实时发送的气泡用的是原文，也没有戳。
//
// 改格式注意：方括号用全角「［］」，与正文区分度更高；字段顺序固定便于模型读。

enum TimeContext {
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E"                    // 周四 / 周日
        f.timeZone = .current
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// 每条用户消息的时间戳前缀：［2026-11-20 17:05 周四］
    static func turnStamp(for date: Date = Date()) -> String {
        "［\(stampFormatter.string(from: date)) \(weekdayFormatter.string(from: date))］"
    }

    /// 距上一条消息的间隔描述。
    /// < 5 分钟不注入（"刚刚"没有信息量）；≥ 5 分钟返回 "距上一条已过去 X 分钟 / X 小时 Y 分钟 / X 天 Y 小时"。
    static func gapText(from previous: Date?, to now: Date = Date()) -> String? {
        guard let previous else { return nil }
        let seconds = now.timeIntervalSince(previous)
        guard seconds >= 300 else { return nil }        // 5 分钟内视为连续聊天
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "距上一条已过去 \(minutes) 分钟"
        }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        if hours < 24 {
            return restMinutes == 0 ? "距上一条已过去 \(hours) 小时"
                                    : "距上一条已过去 \(hours) 小时 \(restMinutes) 分钟"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "距上一条已过去 \(days) 天"
                              : "距上一条已过去 \(days) 天 \(restHours) 小时"
    }

    /// 拼装一条带时间上下文的用户消息（发给模型 + 写进记忆的内容）：
    /// ［时间戳］（距上一条已过去 …）正文
    static func stampedUserMessage(_ text: String, previousMessageTime: Date?, now: Date = Date()) -> String {
        var prefix = turnStamp(for: now)
        if let gap = gapText(from: previousMessageTime, to: now) {
            prefix += "（\(gap)）"
        }
        return text.isEmpty ? prefix : "\(prefix) \(text)"
    }

    /// 去掉用户消息开头的「［时间戳］（距…）」前缀——只用于气泡显示。
    /// 模型与记忆窗口继续看完整带戳文本（时间感知靠它），界面不该被戳污染。
    /// 只有「yyyy-MM-dd HH:mm 周X」形态才当时间戳，避免误伤以 ［ 开头的正常文本。
    static func stripStamp(from text: String) -> String {
        guard text.hasPrefix("［"), let close = text.firstIndex(of: "］") else { return text }
        let inner = text[text.index(after: text.startIndex)..<close]
        guard inner.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2} .+$"#,
                          options: .regularExpression) != nil else { return text }
        var rest = String(text[text.index(after: close)...])
        if rest.hasPrefix("（距上一条已过去"), let gapEnd = rest.firstIndex(of: "）") {
            rest = String(rest[rest.index(after: gapEnd)...])
        }
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return rest
    }
}
