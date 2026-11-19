import Foundation

// MARK: - 日程工具：模型给自己记事用的 schedule_view / schedule_adjust
//
// 这两个工具是常驻的（不受「允许联网搜索」开关影响）——她随时可能临时改主意。
// 注册见 FenShenApp.init；description 文案沿用桌面端插件（里面特意写了
// 「回复里别提到这两个工具」，保持"这是她自己的生活"的幻觉边界）。

/// 查看某天的完整日程（system 注入里只有此刻与接下来几段，想知道全天细节时用）
struct ScheduleViewTool: AgentTool {
    let store: ScheduleStore

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "schedule_view",
            description: "回想自己某一天打算做什么、做过什么（今天 / 明天 / 昨天）。系统提示里只有此刻和接下来几件事，想知道全天或明天的细节时用。这是她自己记事用的，回复里别提到它，也别说「日程上…」。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "day": .object([
                        "type": .string("string"),
                        "enum": .array([.string("today"), .string("tomorrow"), .string("yesterday")]),
                        "description": .string("看哪一天，默认今天。"),
                    ])
                ]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        let day: String
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let requested = obj["day"] as? String {
            day = requested
        } else {
            day = "today"
        }
        guard let key = await ScheduleStore.dayKey(for: day) else {
            return "{\"error\": \"day 只能是 today / tomorrow / yesterday\"}"
        }
        return await MainActor.run { store.dayText(for: key) }
    }
}

/// 临时改计划：用新的一段覆盖某时间段（原有安排被截断或拆开）
struct ScheduleAdjustTool: AgentTool {
    let store: ScheduleStore

    var definition: ToolDefinition {
        ToolDefinition(function: .init(
            name: "schedule_adjust",
            description: "她临时改主意时记一下：用新的一段覆盖某个时间段（原来的打算会被截断或拆开）。比如被约出去吃饭、突然想去散步、活干不完要加班、换了身衣服。只改真的变了的部分。这是她给自己记事用的：回复里直接说她的决定（「那我不出门啦」），别说「我改一下日程 / 调整计划」。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "day": .object([
                        "type": .string("string"),
                        "enum": .array([.string("today"), .string("tomorrow")]),
                        "description": .string("改哪一天，默认今天。"),
                    ]),
                    "start": .object(["type": .string("string"),
                                      "description": .string("开始时间 HH:MM（24 小时制）。")]),
                    "end": .object(["type": .string("string"),
                                    "description": .string("结束时间 HH:MM，24:00 表示到当天结束。")]),
                    "activity": .object(["type": .string("string"),
                                         "description": .string("改成做什么（具体，10 字以内）。")]),
                    "location": .object(["type": .string("string"),
                                         "description": .string("在哪。")]),
                    "detail": .object(["type": .string("string"),
                                       "description": .string("一两句当时的状态或小插曲。")]),
                    "reason": .object(["type": .string("string"),
                                       "description": .string("为什么改主意（例如「朋友约我吃火锅」）。")]),
                    "outfit": .object(["type": .string("string"),
                                       "description": .string("这段穿什么（一件衣服的名字）。换了衣服时填。")]),
                    "outfitNote": .object(["type": .string("string"),
                                           "description": .string("穿搭细节补充（如「外面套了件米色开衫」），没换就不填。")]),
                ]),
                "required": .array([.string("start"), .string("end"),
                                    .string("activity"), .string("reason")]),
            ])))
    }

    func run(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "{\"error\": \"参数需要 JSON 对象\"}"
        }
        let dayName = args["day"] as? String ?? "today"
        let start = args["start"] as? String ?? ""
        let end = args["end"] as? String ?? ""
        let activity = (args["activity"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let reason = args["reason"] as? String ?? "临时改主意"
        let location = args["location"] as? String
        let detail = args["detail"] as? String
        let outfit = args["outfit"] as? String
        let outfitNote = args["outfitNote"] as? String

        guard start.contains(":"), end.contains(":"), !activity.isEmpty else {
            return "{\"error\": \"start/end/activity 必填（时间格式 HH:MM）\"}"
        }
        guard let dateKey = await ScheduleStore.dayKey(for: dayName) else {
            return "{\"error\": \"day 只能是 today / tomorrow\"}"
        }
        await MainActor.run {
            store.adjust(dateKey: dateKey, start: start, end: end,
                         activity: activity, note: reason,
                         location: location?.isEmpty == true ? nil : location,
                         outfit: outfit, outfitNote: outfitNote)
        }
        // 返回给模型的确认话术（提醒它用"自己的口吻"回用户）
        var note = "记下了：\(start)–\(end) \(activity)"
        if let location, !location.isEmpty { note += "（在\(location)）" }
        note += "（原因：\(reason)）。回复里用自己的口吻说决定，别提到工具或「日程」。"
        if let detail, !detail.isEmpty { note += " 状态细节：\(detail)。" }
        return note
    }
}
