import Foundation

// MARK: - 主动消息工具：followup_set / followup_cancel
//
// 闹铃机制里「是否有 n 时间后主动跟进的需要」由模型自己判断：
// 她觉得有必要就在对话里顺手调 followup_set 设一条闹铃，觉得没必要就什么都不做。
// 工具是常驻的（不受「允许联网搜索」开关影响），受插件总开关控制——
// 关闭时 run 会返回明确错误，让她知道这条路走不通。
// 注册见 FenShenApp.init；description 写清「什么时候该用」，触发才准。

/// 设一条「n 分钟后主动找他」的闹铃（到点引擎会唤醒她生成消息，闭环进聊天）
struct FollowupSetTool: AgentTool {
    let store: ProactiveStore

    /// 5 分钟～48 小时。太短像骚扰，太长基本等于遗忘
    static let range: ClosedRange<Int> = 5...2880

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "followup_set",
            description: "记一件「过阵子要主动找他」的事。聊到应该稍后跟进的事时用：他说要去做什么（开会/考试/面试/睡觉前吃药）、答应过给他查东西、你觉得过会儿该关心一下（「2 小时后问问结果」）。到点你会被唤醒、自己开口把这事接上，不用等他回复。 minutes 分钟后触发；intent 写清楚到点想干什么（给未来的你看的便条，越具体越好）；notify 是到点时锁屏通知里显示的一句话，用你的口吻写（可选，不填用兜底文案——App 在后台时只能用预约好的通知敲门，正文回 App 后才生成）。回复里别提到这个工具。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "minutes": .object(["type": .string("integer"),
                                        "description": .string("多少分钟后主动找他（5–2880）。")]),
                    "intent": .object(["type": .string("string"),
                                       "description": .string("到点想干什么、想问什么，写具体（例如「问问面试结果如何，顺便关心他有没有吃午饭」）。")]),
                    "notify": .object(["type": .string("string"),
                                       "description": .string("到点时锁屏通知显示的一句你的口吻的话（20 字内，可选。例如「面完啦？跟俺说说」）。")]),
                ]),
                "required": .array([.string("minutes"), .string("intent")])
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        let enabled = await MainActor.run { store.config.enabled && store.config.alarmEnabled }
        guard enabled else {
            return "{\"error\": \"主动消息功能没有开启，这条路走不通，别再尝试。\"}"
        }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "{\"error\": \"参数需要 JSON 对象 {minutes, intent}\"}"
        }
        // NSNumber（正常 JSON 数字）优先，字符串数字兜底；两者都没有 → 校验失败
        let minutesRaw = (args["minutes"] as? NSNumber)?.intValue ?? Int(args["minutes"] as? String ?? "")
        let intent = (args["intent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notify = (args["notify"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let minutes = minutesRaw, Self.range.contains(minutes) else {
            return "{\"error\": \"minutes 需要是 \(Self.range.lowerBound)–\(Self.range.upperBound) 之间的整数分钟\"}"
        }
        guard !intent.isEmpty else {
            return "{\"error\": \"intent 必填：写清楚到点想干什么，未来的你靠它想起这事\"}"
        }

        let fireAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        let followup = PendingFollowup(createdAt: Date(), fireAt: fireAt,
                                       intent: intent,
                                       notifyText: notify?.isEmpty == true ? nil : notify)
        let note = await MainActor.run { store.addFollowup(followup) }
        return note
    }
}

/// 取消挂起的闹铃（事情提前办完、他说不用了、或者你自己不想问了的反悔通道）
struct FollowupCancelTool: AgentTool {
    let store: ProactiveStore

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "followup_cancel",
            description: "取消所有挂着「过阵子要主动找他」的事。事情提前办完了、他说不用问了、你自己改主意不想提了的时候用。回复里别提到这个工具。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        let enabled = await MainActor.run { store.config.enabled && store.config.alarmEnabled }
        guard enabled else {
            return "{\"error\": \"主动消息功能没有开启\"}"
        }
        let count = await MainActor.run { store.cancelAllFollowups() }
        if count == 0 { return "本来就没有挂着的事。" }
        return "已取消挂起的 \(count) 件事，到点不会再开口。回复里别提到这个工具。"
    }
}
