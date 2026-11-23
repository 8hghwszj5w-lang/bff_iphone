import EventKit
import Foundation

// MARK: - 本机日历 / 提醒事项桥（EventKit，iOS 17 API）
//
// 权限：首次调用会弹系统授权框（文案在 project.yml 的 NS*UsageDescription）。
// 被拒绝时所有方法抛带指引的 Error，工具层会把指引原样返回给模型，
// 模型再告诉用户去哪里开权限。
// 模拟器默认没有日历/提醒数据：返回空列表是正常现象，不是 bug。
//
// 读取一律先转成下面的纯数据快照（DeviceReminderItem / DeviceEventItem），
// 窗口过滤、逾期判定、排序、JSON 渲染都放在 DeviceTools.swift 的纯函数里，
// 这样不依赖真机权限与数据也能单测。语义对齐桌面端 @local/apple-pim。

// MARK: 纯数据快照

/// 提醒事项快照。due = nil 表示没有截止时间。
/// 桌面端 apple-pim 严格只取「有截止且 due < 窗口结束」的提醒；
/// iOS 的 reminders_create 允许不带 due，所以 apple_pim_today 会保留无截止
/// 提醒并排在最后（intentional 偏差，否则这类提醒永远看不见）。
struct DeviceReminderItem: Equatable, Sendable {
    var id: String
    var title: String
    var list: String
    var due: Date?
}

/// 日程事件快照。allDay = true 时 start/end 是本地零点边界（end 为不含的次日零点）。
struct DeviceEventItem: Equatable, Sendable {
    var id: String
    var calendar: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
}

// MARK: - 桥

final class EventKitBridge: NSObject {
    // nonisolated(unsafe)：工具结构体在非隔离上下文构造；实例方法都在主 actor 上
    nonisolated(unsafe) static let shared = EventKitBridge()
    private override init() { super.init() }

    let store = EKEventStore()

    private struct AccessError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: 权限

    /// 请求日历读写权限；返回 nil = 通过，否则返回给用户看的指引文案
    func requestCalendarAccess() async -> String? {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else {
            return "没有日历权限：请到 设置 → 隐私与安全性 → 日历 里允许「分身」（完全访问）。"
        }
        return nil
    }

    /// 请求提醒事项读写权限（新 SDK：async 返回 Bool，无 throws）
    func requestRemindersAccess() async -> String? {
        let granted: Bool
        do { granted = try await store.requestFullAccessToReminders() }
        catch { granted = false }
        guard granted else {
            return "没有提醒事项权限：请到 设置 → 隐私与安全性 → 提醒事项 里允许「分身」。"
        }
        return nil
    }

    // MARK: 读取快照

    /// 某天 00:00–24:00 的事件（跨天事件只要与区间相交就算）。
    /// calendar_read 用整套「当天」范围；apple_pim_today 用多日窗口。
    func eventItems(from start: Date, to end: Date) throws -> [DeviceEventItem] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .map { event in
                DeviceEventItem(
                    id: event.eventIdentifier ?? "",
                    calendar: event.calendar?.title ?? "",
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    allDay: event.isAllDay,
                    location: event.location ?? "")
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.calendar != rhs.calendar { return lhs.calendar < rhs.calendar }
                return lhs.title < rhs.title
            }
    }

    /// 全部未完成的提醒（不按窗口过滤、不截断；过滤与排序交给 ApplePIMSemantics）。
    /// 新 SDK 只暴露 ObjC 风格 fetchReminders(matching:completion:)（完成回调可能多次触发），
    /// 用 OnceFlag 保证续体只 resume 一次。
    func reminderItems() async throws -> [DeviceReminderItem] {
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForReminders(in: calendars)
        let once = OnceFlag()
        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { cont in
            _ = store.fetchReminders(matching: predicate) { list in
                guard once.claim() else { return }
                cont.resume(returning: list ?? [])
            }
        }
        return reminders.filter { !$0.isCompleted }.map { reminder in
            DeviceReminderItem(
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                list: reminder.calendar?.title ?? "",
                // dueDateComponents 可能只有日期（全天到期）→ 归到本地零点，与桌面端一致
                due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
        }
    }

    /// fetchReminders 的完成回调可能被调用多次（先 nil 后结果），只放行第一次
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    // MARK: 写入

    /// 创建日历事件。allDay=true 时按本地零点归一（EventKit 的全天事件要求起止落在零点），
    /// 若归一后结束仍在开始之前（调用方已校验原始 end>start，这里只兜底）就顺延一天。
    func createEvent(title: String, startDate: Date, endDate: Date, allDay: Bool = false,
                     location: String? = nil, notes: String? = nil) throws -> String {
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw AccessError(message: "没有可写入的默认日历（系统设置里日历为空）")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.location = location
        event.notes = notes
        if allDay {
            let cal = Calendar.current
            let start = cal.startOfDay(for: startDate)
            var end = cal.startOfDay(for: endDate)
            if end <= start {
                end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            }
            event.isAllDay = true
            event.startDate = start
            event.endDate = end
        } else {
            event.startDate = startDate
            event.endDate = endDate
        }
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? ""
    }

    func createReminder(title: String, due: Date?) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
}
