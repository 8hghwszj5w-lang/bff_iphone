import EventKit
import Foundation

// MARK: - 本机日历 / 提醒事项桥（EventKit，iOS 17 API）
//
// 权限：首次调用会弹系统授权框（文案在 project.yml 的 NS*UsageDescription）。
// 被拒绝时所有方法抛带指引的 Error，工具层会把指引原样返回给模型，
// 模型再告诉用户去哪里开权限。
// 模拟器默认没有日历/提醒数据：返回空列表是正常现象，不是 bug。

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

    // MARK: 日历读取

    /// 某天 00:00–24:00 的事件（跨天事件只要与区间相交就算）
    func events(on date: Date) throws -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    /// 创建日历事件。时间只给 "HH:MM" 时按 date 当天处理（用于"今天下午三点开会"这类话）。
    func createEvent(title: String, startDate: Date, endDate: Date,
                     location: String? = nil, notes: String? = nil) throws -> String {
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw AccessError(message: "没有可写入的默认日历（系统设置里日历为空）")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.location = location
        event.notes = notes
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? ""
    }

    // MARK: 提醒事项

    /// 未完成的提醒（最多 limit 条）。新 SDK 只暴露 ObjC 风格
    /// fetchReminders(matching:completion:)（完成回调可能多次触发），
    /// 用 OnceFlag 保证续体只 resume 一次。
    func pendingReminders(limit: Int = 20) async throws -> [EKReminder] {
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForReminders(in: calendars)
        let once = OnceFlag()
        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { cont in
            _ = store.fetchReminders(matching: predicate) { list in
                guard once.claim() else { return }
                cont.resume(returning: list ?? [])
            }
        }
        return Array(reminders.filter { !$0.isCompleted }.prefix(limit))
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

    func createReminder(title: String, due: Date?) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier ?? ""
    }
}
