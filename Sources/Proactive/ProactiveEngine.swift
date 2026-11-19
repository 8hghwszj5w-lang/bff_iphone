import Foundation
import UserNotifications
import BackgroundTasks
import UIKit
import Combine

// MARK: - 主动消息插件：通知通道抽象
//
// 引擎不直接碰 UNUserNotificationCenter：统一走 NotificationPosting 协议，
// 离线测试注入 FakePoster 就能验证「什么时刻、发了什么内容、删了哪些预约」。

protocol NotificationPosting: AnyObject {
    /// 请求通知授权（用户开启插件时调用一次；拒绝则通知链路静默失效，前台生成不受影响）
    func ensureAuthorization() async -> Bool
    /// fireAfter == nil 立即横幅；否则预约在 N 秒后送达（App 冻结也能准点，由系统负责）
    func post(id: String, title: String, body: String, fireAfter: TimeInterval?) async
    func remove(id: String) async
    /// 删掉所有 followup 预约通知（回前台/用户开口后，预约敲门就多余了）
    func removeAllFollowupPreviews() async
}

/// 真机通知通道（class：满足 AnyObject 协议约束）。category 带 allowAnnouncement：
/// 用户开启「设置 → Siri → 播报通知」且连着 AirPods 等设备时，Siri 会念出通知正文
/// （App 侧只负责把资格声明到位）。
final class SystemNotificationPoster: NotificationPosting {
    private let center = UNUserNotificationCenter.current()

    static let categoryID = "proactive"
    /// followup 预约通知的 id 前缀（批量清理时按前缀筛）
    static let followupPrefix = "followup-"

    static func registerCategory() {
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [], intentIdentifiers: [],
                                              options: [.allowAnnouncement])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func ensureAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(id: String, title: String, body: String, fireAfter: TimeInterval?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.categoryID
        let trigger = fireAfter.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await center.add(request)
    }

    func remove(id: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func removeAllFollowupPreviews() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(SystemNotificationPoster.followupPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - 主动消息引擎
//
// ┌─ 全景（实现之前和用户确认过的方案）────────────────────────────────┐
// │ 心跳：前台期间每 interval 分钟 tick → 情境加权概率命中 → 调模型生成   │
// │       一条主动消息（模型也可以回 skip = 这次不说）→ 气泡 + 记忆        │
// │ 闹铃：对话里 followup_set 挂起 → 前台到点生成闭环；用户先开口则取消     │
// │ 后台：iOS 冻结后台进程，到点现生成只在「退后台后的存活窗口」内可行：    │
// │       · 窗口内：立刻生成 → 通知带真正文                              │
// │       · 已冻结：预约本地通知准点敲门（正文 = 她设闹铃时顺手写的        │
// │         notifyText，没写就用兜底文案），正文等回 App 再生成（catch-up）│
// │       · BGAppRefresh：系统想起我们时机会性补跑，不保证时间            │
// │ 闭环：所有主动消息 = assistant 气泡 + 写入记忆，用户可接着回复         │
// └──────────────────────────────────────────────────────────────────┘
//
// 想改触发语气/指令文案：makeMessages；想改概率规则：ProactivePolicy。

@MainActor
final class ProactiveEngine: ObservableObject {
    /// 一条已送达聊天流的主·动消息（ChatView 订阅它追加气泡）
    struct Arrival: Identifiable, Equatable {
        let id: UUID
        let text: String
    }

    @Published private(set) var lastArrival: Arrival?
    @Published private(set) var isGenerating = false

    /// 当前是否有用户回合在跑（Pipeline.handle 设置）。生成期间/对话期间不发心跳，
    /// 到点闹铃也压着，等回合结束立刻补——保证她的消息永远排在当前这轮之后。
    private(set) var conversationBusy = false

    /// 设置页与测试访问配置/挂起闹铃；引擎是它的唯一写方（除设置页改 config）
    let store: ProactiveStore
    private let settings: SettingsStore
    private let persona: PersonaStore
    private let memory: MemoryStore
    private let schedule: ScheduleStore?
    private let usage: UsageStore
    private let characterName: String
    /// 真正调模型的一步。用闭包注入而不是直接持有 DeepSeekClient：
    /// 离线测试喂固定回答即可覆盖 skip / 成功 / 失败三条路径，不烧 API。
    private let ask: @MainActor ([ChatMessage]) async throws -> (String, Int, Int)
    let poster: NotificationPosting

    private var heartbeatTimer: Timer?
    private var alarmTimer: Timer?
    private var bgTaskID = UIBackgroundTaskIdentifier.invalid

    /// 后台存活窗口内「马上要响的闹铃」的提前量：窗口约 30 秒，取 90 秒够用
    static let imminentWindow: TimeInterval = 90
    static let bgTaskID = "local.fenshen.proactive.refresh"
    /// 预约通知的兜底文案：她设闹铃时没顺手写 notifyText 时用
    static let fallbackPreviewText = "她惦记着一件事，想跟你说两句"

    init(store: ProactiveStore,
         settings: SettingsStore,
         persona: PersonaStore,
         memory: MemoryStore,
         schedule: ScheduleStore?,
         usage: UsageStore,
         characterName: String = "小深",
         ask: @escaping @MainActor ([ChatMessage]) async throws -> (String, Int, Int),
         poster: NotificationPosting = SystemNotificationPoster()) {
        self.store = store
        self.settings = settings
        self.persona = persona
        self.memory = memory
        self.schedule = schedule
        self.usage = usage
        self.characterName = characterName
        self.ask = ask
        self.poster = poster
    }

    /// App 启动时调一次（不能放 init：测试里构造引擎不该注册 BG 任务/起定时器）
    func applicationStarted() {
        SystemNotificationPoster.registerCategory()
        registerBGRefresh()
        if store.config.enabled {
            startTimers()
            Task { [weak self] in
                guard let self, self.store.config.enabled, self.store.config.alarmEnabled else { return }
                _ = await self.poster.ensureAuthorization()
            }
        }
    }

    // MARK: 前后台切换（ChatView 挂 scenePhase 钩子）

    func handleActive() {
        guard store.config.enabled else { return }
        // 回前台后预约通知失去意义（正文会在前台现生成），全清
        Task { await poster.removeAllFollowupPreviews() }
        startTimers()          // 重建定时器，顺带清掉后台挂起期间的时间漂移
        checkAlarms()          // 冻结期间到点的闹铃，此刻 catch-up 生成
    }

    func handleBackground() {
        guard store.config.enabled else { return }
        beginGraceWindow()
        Task { [weak self] in
            guard let self else { return }
            await self.generateImminentFollowupInBackground()
            await self.scheduleFollowupPreviews()
            self.scheduleNextBGRefresh()
            self.endGraceWindow()
        }
    }

    // MARK: 用户回合（Pipeline.handle 首尾调用）

    /// 用户开口 = 她挂起的那件事已经在对话里发生过了，闭环提前完成，闹铃取消。
    /// async：清预约通知要在返回前完成（Pipeline 在 async 上下文调用）。
    func beginUserTurn() async {
        conversationBusy = true
        if store.cancelAllFollowups() > 0 {
            await poster.removeAllFollowupPreviews()
        }
    }

    func endUserTurn() {
        conversationBusy = false
        checkAlarms()          // 回合结束立刻补跑被压着的到点闹铃
    }

    // MARK: 设置变更（设置页 onChange 调用）

    func applyConfig() {
        let c = store.config
        guard c.enabled else {
            stopTimers()
            _ = store.cancelAllFollowups()
            Task { await poster.removeAllFollowupPreviews() }
            return
        }
        if !c.alarmEnabled {
            _ = store.cancelAllFollowups()
            Task { await poster.removeAllFollowupPreviews() }
        } else {
            Task { await poster.ensureAuthorization() }
        }
        startTimers()          // 间隔可能改了，重建
    }

    func cancelFollowup(id: UUID) {
        store.cancelFollowup(id: id)
        Task { await poster.remove(id: SystemNotificationPoster.followupPrefix + id.uuidString) }
    }

    // MARK: 定时器

    private func startTimers() {
        stopTimers()
        let interval = Double(max(5, store.config.heartbeatIntervalMinutes)) * 60
        let heartbeat = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.heartbeatTick() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        heartbeatTimer = heartbeat
        let alarm = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAlarms() }
        }
        RunLoop.main.add(alarm, forMode: .common)
        alarmTimer = alarm
    }

    private func stopTimers() {
        heartbeatTimer?.invalidate()
        alarmTimer?.invalidate()
        heartbeatTimer = nil
        alarmTimer = nil
    }

    /// 心跳 tick：只是掷一次骰子，绝大多数 tick 什么都不做（这就是省 token 的设计）
    private func heartbeatTick() {
        let c = store.config
        guard c.enabled, c.heartbeatEnabled, !conversationBusy, !isGenerating else { return }
        let now = Date()
        let roll = Double.random(in: 0..<1)
        guard ProactivePolicy.heartbeatTriggered(
            config: c,
            minuteOfDay: ProactivePolicy.minuteOfDay(now),
            minutesSinceLastUser: minutesSinceLastUserMessage(now: now),
            minutesSinceLastProactive: store.lastProactiveAt.map { now.timeIntervalSince($0) / 60 },
            roll: roll
        ) else { return }
        Task { await generate(.heartbeat) }
    }

    /// 定时器/回合结束触发的入口：包成 Task 异步补跑
    private func checkAlarms() {
        Task { _ = await fireDueFollowupIfNeeded() }
    }

    /// 到点闹铃补跑。conversationBusy / 免打扰时段内一律压着，下一轮检查再试。
    /// 可直接 await（离线测试用它做确定性验证），定时器路径包在 Task 里。
    @discardableResult
    func fireDueFollowupIfNeeded() async -> Bool {
        let c = store.config
        guard c.enabled, c.alarmEnabled, !conversationBusy, !isGenerating else { return false }
        guard let due = store.dueFollowups(now: Date()).first else { return false }
        return await generate(.followup(due)) != nil
    }

    private func minutesSinceLastUserMessage(now: Date) -> Double? {
        memory.record.entries.last(where: { $0.role == "user" })
            .map { now.timeIntervalSince($0.time) / 60 }
    }

    // MARK: 生成管线（闭环：气泡 + 记忆 + 用量）

    private enum GenerationKind {
        case heartbeat
        case followup(PendingFollowup)
    }

    /// 生成并送达一条主动消息。返回正文（nil = 她选择不说 / 请求失败）。
    /// 成功路径：清洗 → 写记忆（闭环）→ 发 Arrival（ChatView 出气泡）→ 记节奏。
    @discardableResult
    private func generate(_ kind: GenerationKind) async -> String? {
        guard !isGenerating else { return nil }
        isGenerating = true
        defer { isGenerating = false }

        do {
            let (raw, promptTokens, completionTokens) = try await ask(makeMessages(for: kind))
            usage.append(promptTokens: promptTokens, completionTokens: completionTokens)
            guard let text = ProactivePolicy.cleanProactiveText(raw) else {
                // 她决定这次不说。闹铃视为已兑现并移除（免得下轮又催她）；
                // 心跳则纯粹白花一次调用，什么都不发生。
                if case .followup(let f) = kind { store.cancelFollowup(id: f.id) }
                return nil
            }
            // 闭环三件套：进记忆（上下文连贯）→ 出气泡（用户可见可回复）→ 记冷却起点
            memory.append(role: "assistant", content: text, maxHistory: settings.maxHistory)
            store.noteProactiveSent()
            lastArrival = Arrival(id: UUID(), text: text)
            if case .followup(let f) = kind {
                store.cancelFollowup(id: f.id)
                await poster.remove(id: SystemNotificationPoster.followupPrefix + f.id.uuidString)
            }
            return text
        } catch {
            // 生成失败：闹铃推迟 10 分钟重试（满 3 次自动放弃）；心跳本次放弃
            if case .followup(let f) = kind {
                if store.deferFollowup(id: f.id) == nil {
                    await poster.remove(id: SystemNotificationPoster.followupPrefix + f.id.uuidString)
                }
            }
            return nil
        }
    }

    private func makeMessages(for kind: GenerationKind) -> [ChatMessage] {
        // 与 Pipeline 同一套上下文：人设 + 她此刻的生活背景 + 记忆窗口。
        // 生图说明不注入——主动消息保持纯文本，便宜且不触发画画。
        let scheduleBlock = schedule?.injectionText(now: Date()) ?? ""
        var context = memory.contextMessages(persona: persona.text, scheduleBlock: scheduleBlock)
        let instruction: String
        switch kind {
        case .heartbeat:
            instruction = """
            【此刻没有新消息。是你自己想找他说话，不是在回复。】
            - 上面是最近的聊天记录，现在你想起了什么就说什么：分享、吐槽、追问、接旧话题都行。
            - 用她的口吻直接输出这条消息本身，一两条短句，别写旁白、别解释你在干什么。
            - 如果此刻真的没什么想说的，就只输出：（skip）
            """
        case .followup(let f):
            let elapsed = max(1, Int(Date().timeIntervalSince(f.createdAt) / 60))
            instruction = """
            【此刻没有新消息。是你自己记着一件事，到点来找他。】
            - \(Self.elapsedLabel(minutes: elapsed))前你记下过一件事：\(f.intent)
            - 现在到点了。像真人想起这事那样开口：把事情自然带到，他可能已经忘了细节，你要把上下文补上。
            - 这期间的新聊天记录都当作已经发生过的事实，别再问已经聊过的事。
            - 如果时机已经不对（这事明显被聊过了、或者已经不成立了），就只输出：（skip）
            """
        }
        context.append(.user(instruction))
        return context
    }

    static func elapsedLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60
        if h < 24 { return h == 1 ? "1 个小时" : "\(h) 个小时" }
        return "\(minutes / 60 / 24) 天"
    }

    // MARK: 后台衔接（存活窗口 + 预约通知 + BGAppRefresh）

    /// 退后台的存活窗口内（约 30 秒），把 90 秒内要响的闹铃立刻生成掉，
    /// 通知里放的是真正文；远期闹铃走预约预览，正文回 App 再生成。
    private func generateImminentFollowupInBackground() async {
        guard !conversationBusy, !isGenerating,
              store.config.alarmEnabled,
              !ProactivePolicy.isInQuietHours(Date(), config: store.config) else { return }
        let now = Date()
        let imminent = store.state.followups
            .map { ($0, ProactivePolicy.effectiveFireDate($0.fireAt, config: store.config)) }
            .filter { $1 <= now.addingTimeInterval(Self.imminentWindow) }
            .min { $0.1 < $1.1 }?.0
        guard let f = imminent else { return }
        if let text = await generate(.followup(f)) {
            await poster.post(id: SystemNotificationPoster.followupPrefix + f.id.uuidString,
                              title: characterName, body: text, fireAfter: 0.5)
        }
    }

    /// 给所有仍挂起的闹铃预约「敲门」通知：正文用她设闹铃时顺手写的 notifyText，
    /// 没写就用兜底文案——因为已冻结的 App 无法到点现生成，这是唯一的准时手段。
    /// 已过期但被压着的闹铃（免打扰/对话中）同样顺延到免打扰结束后再敲门。
    private func scheduleFollowupPreviews() async {
        await poster.removeAllFollowupPreviews()
        let now = Date()
        let quietNow = ProactivePolicy.isInQuietHours(now, config: store.config)
        for f in store.state.followups {
            var delay = ProactivePolicy.effectiveFireDate(f.fireAt, config: store.config).timeIntervalSince(now)
            if delay <= 0 && quietNow {
                delay = ProactivePolicy.quietEnd(after: now, config: store.config).timeIntervalSince(now)
            }
            await poster.post(id: SystemNotificationPoster.followupPrefix + f.id.uuidString,
                              title: characterName,
                              body: (f.notifyText?.isEmpty == false ? f.notifyText! : Self.fallbackPreviewText),
                              fireAfter: delay > 0 ? delay : 1)
        }
    }

    // MARK: 后台任务窗口（beginBackgroundTask，约 30 秒宽限）

    private func beginGraceWindow() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "proactive") { [weak self] in
            Task { @MainActor [weak self] in self?.endGraceWindow() }
        }
    }

    private func endGraceWindow() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: BGAppRefresh（机会性补跑，系统不保证何时给时间）

    /// BGTaskScheduler 对同一标识符只允许注册一次（重复注册触发断言崩溃，
    /// 测试宿主里 AppState 可能构造多次），进程级守卫保证只走第一次。
    private static var bgRefreshRegistered = false

    private func registerBGRefresh() {
        guard !Self.bgRefreshRegistered else { return }
        Self.bgRefreshRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskID, using: nil) { [weak self] task in
            Task { @MainActor [weak self] in
                await self?.handleBGRefresh(task as? BGAppRefreshTask)
            }
        }
    }

    private func scheduleNextBGRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        // 有挂起闹铃就在其到点后申请机会；没有就只留个机会性请求
        let next = store.state.followups
            .map { ProactivePolicy.effectiveFireDate($0.fireAt, config: store.config) }
            .min()
        request.earliestBeginDate = next
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBGRefresh(_ task: BGAppRefreshTask?) async {
        scheduleNextBGRefresh()
        guard let task else { return }
        let c = store.config
        guard c.enabled, c.alarmEnabled, !conversationBusy, !isGenerating else {
            task.setTaskCompleted(success: false)
            return
        }
        guard let f = store.dueFollowups(now: Date()).first else {
            task.setTaskCompleted(success: true)
            return
        }
        beginGraceWindow()
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.endGraceWindow() }
        }
        let text = await generate(.followup(f))
        if let text {
            await poster.post(id: SystemNotificationPoster.followupPrefix + f.id.uuidString,
                              title: characterName, body: text, fireAfter: 0.5)
        }
        endGraceWindow()
        task.setTaskCompleted(success: text != nil)
    }
}
