import Foundation

// MARK: - 主动消息插件：配置 + 纯判定逻辑
//
// 这个文件只有「数据和数学」：配置结构、挂起闹铃模型、免打扰判断、
// 到点顺延计算、心跳情境加权概率。全部是注入输入的纯函数，没有任何
// 定时器 / 通知 / 网络副作用——副作用都在 ProactiveEngine，
// 这样 Policy 可以（也必须）被离线测试覆盖（见 Tests/ProactiveTests.swift）。
//
// 两条触发路径（与用户确认过的方案一一对应）：
// · 闹铃机制：对话里模型自己用 followup_set 设「n 分钟后主动跟进」，
//   到点唤醒模型生成消息闭环；到点落在免打扰时段会顺延到时段结束。
// · 心跳机制：前台期间每隔 interval 分钟 tick 一次，按情境加权概率
//   掷骰子，命中才真正调模型（省 token，也避免话痨）。

/// 插件配置（持久化到 UserDefaults，见 ProactiveStore）
struct ProactiveConfig: Codable, Equatable {
    /// 插件总开关。关闭时：不声明 followup 工具行为失效、定时器全停、挂起闹铃清空
    var enabled = true
    /// 闹铃机制开关（followup_set / followup_cancel + 到点生成）
    var alarmEnabled = true
    /// 心跳机制开关（定时 tick + 概率触发）
    var heartbeatEnabled = true
    /// 心跳 tick 间隔（分钟）。每次 tick 都是一次概率判断，不是每次都调模型
    var heartbeatIntervalMinutes = 10
    /// 心跳基础概率（0...0.5）。实际触发概率 = 基础概率 × 情境加权因子
    var heartbeatBaseProbability = 0.15
    /// 两次主动消息（心跳或闹铃都算）之间的最小间隔（分钟），防话痨
    var proactiveCooldownMinutes = 45
    /// 免打扰开始（当日分钟数，默认 23:30）。时段内心跳概率为 0、闹铃顺延
    var quietStartMinute = 23 * 60 + 30
    /// 免打扰结束（当日分钟数，默认 08:00）
    var quietEndMinute = 8 * 60
}

/// 一条挂起的「闹铃」：模型在对话里设下的、n 分钟后要主动跟进的事
struct PendingFollowup: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 设下时间（给到点生成时算「过了多久」用）
    var createdAt: Date
    /// 原定触发时间。实际触发/通知时间会用 Policy.effectiveFireDate 做免打扰顺延
    var fireAt: Date
    /// 到点后她想干什么、想问什么（模型写给未来自己的便条，生成时的核心输入）
    var intent: String
    /// 到点时锁屏通知的预览文案（模型顺手用她的口吻写的；nil 用兜底文案）。
    /// 为什么提前写：App 冻结在后台时无法到点现生成，只能用预约好的通知先敲门，
    /// 正文等用户回 App 再真正生成（见 ProactiveEngine.generate）
    var notifyText: String?
    /// 生成失败自动重试次数；满 3 次放弃这条闹铃
    var attempts = 0
}

// MARK: - 纯判定逻辑

enum ProactivePolicy {
    // MARK: 免打扰时段

    /// 某时刻的「当日分钟数」（0...1439）
    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// 该分钟是否落在免打扰时段。支持跨午夜（23:30–08:00 这种 start > end）；
    /// start == end 视为「没有免打扰时段」。
    static func isInQuietHours(minuteOfDay m: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return m >= start && m < end }
        return m >= start || m < end
    }

    static func isInQuietHours(_ date: Date, config: ProactiveConfig, calendar: Calendar = .current) -> Bool {
        isInQuietHours(minuteOfDay: minuteOfDay(date, calendar: calendar),
                       start: config.quietStartMinute, end: config.quietEndMinute)
    }

    /// 免打扰时段的「结束时刻」。只在 date 落在时段内时有意义；
    /// 跨午夜段（如 23:30 起）结束时已经是次日，所以 end 要加一天。
    static func quietEnd(after date: Date, config: ProactiveConfig,
                         calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let m = minuteOfDay(date, calendar: calendar)
        let crossesMidnight = config.quietStartMinute > config.quietEndMinute
        let endOffset = (crossesMidnight && m >= config.quietStartMinute)
            ? config.quietEndMinute + 24 * 60
            : config.quietEndMinute
        return calendar.date(byAdding: .minute, value: endOffset, to: dayStart) ?? date
    }

    /// 闹铃的实际触发时刻：原定时刻落在免打扰时段内 → 顺延到时段结束。
    /// 已过期且不在免打扰时段 → 原样返回（立即到点）。
    static func effectiveFireDate(_ fireAt: Date, config: ProactiveConfig,
                                  calendar: Calendar = .current) -> Date {
        guard isInQuietHours(fireAt, config: config, calendar: calendar) else { return fireAt }
        return quietEnd(after: fireAt, config: config, calendar: calendar)
    }

    // MARK: 心跳情境加权概率

    /// 一次心跳 tick 的实际触发概率。情境加权规则（都可在测试里逐条验证）：
    /// · 免打扰时段 → 0（绝不主动打扰）
    /// · 距上次主动消息不足冷却期 → 0（防话痨）
    /// · 距用户上一条消息不足 2 分钟 → 0（话音未落别抢话）
    /// · 距上次用户消息越久越想找他（30 分钟爬满）× 0.15～1.0；
    ///   从没有记录时取 0.8（新装 App 她也可以先开口打招呼）
    /// · 深夜但还没到免打扰（22:00 起）× 0.5（人在犯困，主动欲降低）
    /// · 上限 0.6，避免权重叠乘后变成每次必发
    static func heartbeatProbability(config: ProactiveConfig,
                                     minuteOfDay m: Int,
                                     minutesSinceLastUser: Double?,
                                     minutesSinceLastProactive: Double?) -> Double {
        guard config.heartbeatEnabled, config.heartbeatBaseProbability > 0 else { return 0 }
        if isInQuietHours(minuteOfDay: m,
                          start: config.quietStartMinute, end: config.quietEndMinute) {
            return 0
        }
        if let since = minutesSinceLastProactive,
           since < Double(config.proactiveCooldownMinutes) {
            return 0
        }
        if let since = minutesSinceLastUser, since < 2 { return 0 }

        let freshness: Double
        if let since = minutesSinceLastUser {
            freshness = min(1.0, max(0.15, since / 30.0))
        } else {
            freshness = 0.8
        }
        var p = config.heartbeatBaseProbability * freshness
        if m >= 22 * 60 && m < max(22 * 60, config.quietStartMinute) { p *= 0.5 }
        return min(p, 0.6)
    }

    /// 一次心跳 tick 是否触发。`roll` 是外部传入的 [0,1) 随机数——
    /// 随机性放参数里，判断本身保持纯函数可测。
    static func heartbeatTriggered(config: ProactiveConfig,
                                   minuteOfDay m: Int,
                                   minutesSinceLastUser: Double?,
                                   minutesSinceLastProactive: Double?,
                                   roll: Double) -> Bool {
        roll < heartbeatProbability(config: config,
                                    minuteOfDay: m,
                                    minutesSinceLastUser: minutesSinceLastUser,
                                    minutesSinceLastProactive: minutesSinceLastProactive)
    }

    // MARK: 生成结果清洗

    /// 模型被允许「这次不说话」：输出 skip 标记就不发消息、不进记忆。
    /// 返回 nil 表示放弃本次；否则返回清洗后的正文。
    static func cleanProactiveText(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 偶尔会带代码围栏/空行，与 Pipeline.clean 同一套洁癖
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = t.lowercased()
        if t.isEmpty || lowered.contains("(skip)") || lowered.contains("（skip）") { return nil }
        return t
    }
}
