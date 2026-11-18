import Foundation

// MARK: - 每日日程数据模型（移植 DSH 插件 dsh-daily-schedule 的 schedule.js）
//
// 一天的日程形状（与桌面端插件同构）：
//   { date: "yyyy-MM-dd", dayTypeName?, title?, mood?,
//     items: [{ start: "HH:MM", end: "HH:MM", activity, location?, detail? }],
//     changes: [{ at, note }] }
// items 经过 normalize 保证：排序、不重叠、从 00:00 连续覆盖到 24:00、至多 40 条。

struct ScheduleItem: Codable, Equatable {
    var start: String        // "HH:MM"（end 允许 "24:00"）
    var end: String
    var activity: String
    var location: String?
    var detail: String?

    var startMinute: Int { Self.minutes(of: start) ?? 0 }
    var endMinute: Int { Self.minutes(of: end) ?? 1440 }
    var isSleep: Bool { activity.contains("睡") }

    var placeLabel: String {
        if let location, !location.isEmpty { return "（\(location)）" }
        return ""
    }

    static func minutes(of clock: String) -> Int? {
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func clock(minutes: Int) -> String {
        let clamped = min(1440, max(0, minutes))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

struct ScheduleChange: Codable, Equatable {
    var at: Date
    var note: String
}

struct DaySchedule: Codable, Equatable {
    var date: String                 // yyyy-MM-dd
    var dayTypeName: String? = nil   // 上班日 / 休息日 / 外出日…
    var title: String? = nil
    var mood: String? = nil
    var items: [ScheduleItem] = []
    var changes: [ScheduleChange]? = nil

    func findItem(atMinute minute: Int) -> Int {
        items.firstIndex { minute >= $0.startMinute && minute < $0.endMinute } ?? -1
    }
}

enum ScheduleNormalizer {
    /// 插件 normalizeItems 的移植：排序、去重叠、补空档，保证 00:00–24:00 全覆盖。
    /// 空档按官方规则补「睡觉 / 在家休息」；最后一段不足则补到 24:00；上限 40 条。
    static func normalize(_ list: [ScheduleItem]) -> [ScheduleItem] {
        var items = list.filter { $0.endMinute > $0.startMinute }
        items.sort { $0.startMinute == $1.startMinute ? $0.endMinute < $1.endMinute
                                                   : $0.startMinute < $1.startMinute }

        var out: [ScheduleItem] = []
        for var item in items {
            if let prev = out.last {
                if item.endMinute <= prev.endMinute { continue }          // 完全被上一条覆盖
                if item.startMinute < prev.endMinute {                    // 交集：起点顺延到上一条结尾
                    item.start = ScheduleItem.clock(minutes: prev.endMinute)
                }
            }
            if item.endMinute > item.startMinute { out.append(item) }
        }
        // 中间空档补「在家休息」：注入的 findItem 需要全天连续覆盖，
        // 否则空档里查不到"此刻在做什么"（桌面端不补中段，这里比它更完整）
        var filled: [ScheduleItem] = []
        for (index, item) in out.enumerated() {
            filled.append(item)
            if index + 1 < out.count, out[index + 1].startMinute > item.endMinute {
                filled.append(restItem(from: item.endMinute, to: out[index + 1].startMinute))
            }
        }
        out = filled

        // 空日程兜底：整日在家
        if out.isEmpty {
            return [ScheduleItem(start: "00:00", end: "24:00",
                                 activity: "在家", location: "家", detail: nil)]
        }
        // 开头有空档 → 睡觉
        if out[0].startMinute > 0 {
            out.insert(sleepItem(from: 0, to: out[0].startMinute), at: 0)
        }
        // 结尾：先补"在家休息"到 23:00（1380），再补"睡觉"到 24:00（1440）——同官方规则
        if let last = out.last, last.endMinute < 1380 {
            out.append(restItem(from: last.endMinute, to: 1380))
        }
        if let last = out.last, last.endMinute < 1440 {
            out.append(sleepItem(from: last.endMinute, to: 1440))
        }
        return Array(out.prefix(40))
    }

    private static func sleepItem(from: Int, to: Int) -> ScheduleItem {
        ScheduleItem(start: ScheduleItem.clock(minutes: from),
                     end: ScheduleItem.clock(minutes: to),
                     activity: "睡觉", location: "家", detail: nil)
    }

    private static func restItem(from: Int, to: Int) -> ScheduleItem {
        ScheduleItem(start: ScheduleItem.clock(minutes: from),
                     end: ScheduleItem.clock(minutes: to),
                     activity: "在家休息", location: "家", detail: nil)
    }
}
