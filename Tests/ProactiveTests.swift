import XCTest
@testable import FenShen

// MARK: - 主动消息插件离线回归
//
// 覆盖三层（都不联网、不烧 API、时间无关——把免打扰时段设为 start==end
// 禁用掉，避免深夜跑测试时被真实时间影响）：
// · Policy：免打扰矩阵、到点顺延、心跳情境加权概率、skip 清洗
// · Store：挂起闹铃增删/上限/到期/失败重试 + 落盘重启恢复
// · Engine：catch-up 生成闭环（气泡/记忆/通知清理）、skip、失败重试、对话期间压住

@MainActor
final class ProactiveTests: XCTestCase {
    // MARK: 沙盒工具

    private struct Box {
        let store: ProactiveStore
        let engine: ProactiveEngine
        let memory: MemoryStore
        let usage: UsageStore
        let poster: FakePoster
        let defaults: UserDefaults
        let suiteName: String
        let directory: URL
    }

    private func makeBox(ask: @escaping @MainActor ([ChatMessage]) async throws -> (String, Int, Int)) -> Box {
        let suiteName = "proactive-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proactive-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ProactiveStore(directory: directory, defaults: defaults)
        // 禁用免打扰时段（start == end 永不触发），让测试与运行时刻的钟点无关
        store.config.quietStartMinute = 0
        store.config.quietEndMinute = 0
        let memory = MemoryStore(directory: directory.appendingPathComponent("memory", isDirectory: true))
        let usage = UsageStore(directory: directory)
        let poster = FakePoster()
        let engine = ProactiveEngine(store: store,
                                     settings: SettingsStore(defaults: defaults),
                                     persona: PersonaStore(),
                                     memory: memory,
                                     schedule: nil,
                                     usage: usage,
                                     ask: ask,
                                     poster: poster)
        return Box(store: store, engine: engine, memory: memory, usage: usage,
                   poster: poster, defaults: defaults, suiteName: suiteName, directory: directory)
    }

    private final class FakePoster: NotificationPosting {
        struct Post {
            let id: String
            let title: String
            let body: String
            let fireAfter: TimeInterval?
        }
        private(set) var posts: [Post] = []
        private(set) var removed: [String] = []
        private(set) var removeAllCount = 0

        func ensureAuthorization() async -> Bool { true }
        func post(id: String, title: String, body: String, fireAfter: TimeInterval?) async {
            posts.append(Post(id: id, title: title, body: body, fireAfter: fireAfter))
        }
        func remove(id: String) async { removed.append(id) }
        func removeAllFollowupPreviews() async { removeAllCount += 1 }
    }

    // MARK: Policy · 免打扰

    func testQuietHoursWithoutMidnightCrossing() {
        // 10:00–12:00
        XCTAssertTrue(ProactivePolicy.isInQuietHours(minuteOfDay: 10 * 60 + 30, start: 600, end: 720))
        XCTAssertFalse(ProactivePolicy.isInQuietHours(minuteOfDay: 9 * 60, start: 600, end: 720))
        XCTAssertFalse(ProactivePolicy.isInQuietHours(minuteOfDay: 12 * 60, start: 600, end: 720)) // 右开区间
        XCTAssertTrue(ProactivePolicy.isInQuietHours(minuteOfDay: 11 * 60 + 59, start: 600, end: 720))
    }

    func testQuietHoursCrossingMidnight() {
        // 23:30–08:00
        let start = 23 * 60 + 30, end = 8 * 60
        XCTAssertTrue(ProactivePolicy.isInQuietHours(minuteOfDay: 23 * 60 + 45, start: start, end: end))
        XCTAssertTrue(ProactivePolicy.isInQuietHours(minuteOfDay: 0, start: start, end: end))
        XCTAssertTrue(ProactivePolicy.isInQuietHours(minuteOfDay: 7 * 60 + 59, start: start, end: end))
        XCTAssertFalse(ProactivePolicy.isInQuietHours(minuteOfDay: 8 * 60, start: start, end: end))
        XCTAssertFalse(ProactivePolicy.isInQuietHours(minuteOfDay: 12 * 60, start: start, end: end))
        XCTAssertFalse(ProactivePolicy.isInQuietHours(minuteOfDay: 23 * 60, start: start, end: end))
    }

    func testQuietHoursDisabledWhenStartEqualsEnd() {
        XCTAssertFalse(ProactivePolicy.isInQuietHours(minuteOfDay: 3 * 60, start: 0, end: 0))
    }

    func testEffectiveFireDateDefersQuietEndAcrossMidnight() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 19
        comps.hour = 23; comps.minute = 45
        let calendar = Calendar(identifier: .gregorian)
        let fireAt = calendar.date(from: comps)!
        var config = ProactiveConfig()
        config.quietStartMinute = 23 * 60 + 30
        config.quietEndMinute = 8 * 60
        let eff = ProactivePolicy.effectiveFireDate(fireAt, config: config, calendar: calendar)
        // 23:45 落在免打扰 → 顺延到次日 08:00
        let expected = calendar.date(byAdding: .minute, value: 8 * 60 + 24 * 60, to: calendar.startOfDay(for: fireAt))!
        XCTAssertEqual(eff, expected)
        // 不在免打扰的时刻原样返回
        let noon = calendar.date(byAdding: .hour, value: -12, to: fireAt)!
        XCTAssertEqual(ProactivePolicy.effectiveFireDate(noon, config: config, calendar: calendar), noon)
    }

    // MARK: Policy · 心跳概率

    private func prob(_ config: ProactiveConfig, minute: Int,
                      sinceUser: Double?, sinceProactive: Double?) -> Double {
        ProactivePolicy.heartbeatProbability(config: config, minuteOfDay: minute,
                                             minutesSinceLastUser: sinceUser,
                                             minutesSinceLastProactive: sinceProactive)
    }

    func testHeartbeatZeroInQuietOrCooldownOrFreshUser() {
        var c = ProactiveConfig()
        c.quietStartMinute = 23 * 60 + 30
        c.quietEndMinute = 8 * 60
        // 免打扰 → 0
        XCTAssertEqual(prob(c, minute: 3 * 60, sinceUser: 120, sinceProactive: 200), 0)
        // 冷却期内（距上次主动消息 10 分钟 < 45）→ 0
        XCTAssertEqual(prob(c, minute: 14 * 60, sinceUser: 60, sinceProactive: 10), 0)
        // 用户刚说话不到 2 分钟 → 0（别抢话）
        XCTAssertEqual(prob(c, minute: 14 * 60, sinceUser: 1, sinceProactive: 100), 0)
    }

    func testHeartbeatProbabilityGrowsWithSilenceAndCaps() {
        var c = ProactiveConfig()
        c.heartbeatBaseProbability = 0.2
        // 刚聊完 3 分钟：新鲜度压到下限 0.15 → 0.2 * 0.15
        let fresh = prob(c, minute: 12 * 60, sinceUser: 3, sinceProactive: 60)
        XCTAssertEqual(fresh, 0.2 * 0.15, accuracy: 0.0001)
        // 沉默 40 分钟：新鲜度爬满 1.0
        let long = prob(c, minute: 12 * 60, sinceUser: 40, sinceProactive: 60)
        XCTAssertEqual(long, 0.2, accuracy: 0.0001)
        // 没有任何记录：默认 0.8 档
        let noHistory = prob(c, minute: 12 * 60, sinceUser: nil, sinceProactive: nil)
        XCTAssertEqual(noHistory, 0.2 * 0.8, accuracy: 0.0001)
        // 权重再大也不超过 0.6 上限
        c.heartbeatBaseProbability = 0.5
        XCTAssertEqual(prob(c, minute: 12 * 60, sinceUser: 999, sinceProactive: 999), 0.5, accuracy: 0.0001)
        // 深夜（22:00 后、免打扰前）减半
        XCTAssertEqual(prob(c, minute: 22 * 60 + 30, sinceUser: 999, sinceProactive: 999), 0.25, accuracy: 0.0001)
    }

    func testHeartbeatTriggeredUsesRoll() {
        var c = ProactiveConfig()
        c.heartbeatBaseProbability = 0.2
        XCTAssertTrue(ProactivePolicy.heartbeatTriggered(config: c, minuteOfDay: 12 * 60,
                                                         minutesSinceLastUser: 60,
                                                         minutesSinceLastProactive: 60,
                                                         roll: 0.1))
        XCTAssertFalse(ProactivePolicy.heartbeatTriggered(config: c, minuteOfDay: 12 * 60,
                                                          minutesSinceLastUser: 60,
                                                          minutesSinceLastProactive: 60,
                                                          roll: 0.3))
    }

    // MARK: Policy · 生成清洗

    func testCleanProactiveTextSkipAndCleanup() {
        XCTAssertNil(ProactivePolicy.cleanProactiveText("（skip）"))
        XCTAssertNil(ProactivePolicy.cleanProactiveText("(SKIP)"))
        XCTAssertNil(ProactivePolicy.cleanProactiveText("   "))
        XCTAssertEqual(ProactivePolicy.cleanProactiveText("  面完啦？\n\n\n\n跟俺说说  "), "面完啦？\n\n跟俺说说")
    }

    // MARK: Store

    func testStoreAddCancelDueAndCap() {
        let box = makeBox { _ in ("ok", 0, 0) }
        let now = Date()
        let f1 = PendingFollowup(createdAt: now, fireAt: now.addingTimeInterval(-60), intent: "问问面试")
        let f2 = PendingFollowup(createdAt: now, fireAt: now.addingTimeInterval(3600), intent: "提醒睡觉")
        let note = box.store.addFollowup(f1, now: now)
        XCTAssertTrue(note.contains("记下了"))
        box.store.addFollowup(f2, now: now)
        // 到期筛选：只有 f1
        XCTAssertEqual(box.store.dueFollowups(now: now).map(\.intent), ["问问面试"])
        // 重复意图拒绝
        XCTAssertTrue(box.store.addFollowup(f1, now: now).contains("已经记下了"))
        // 上限 5 条
        for i in 0..<5 {
            box.store.addFollowup(PendingFollowup(createdAt: now,
                                                  fireAt: now.addingTimeInterval(60),
                                                  intent: "杂事\(i)"), now: now)
        }
        XCTAssertEqual(box.store.state.followups.count, ProactiveStore.maxFollowups)
        XCTAssertTrue(box.store.addFollowup(PendingFollowup(createdAt: now, fireAt: now, intent: "第6件"), now: now)
            .contains("太多"))
        // 全部取消
        XCTAssertEqual(box.store.cancelAllFollowups(), ProactiveStore.maxFollowups)
        XCTAssertTrue(box.store.state.followups.isEmpty)
    }

    func testStoreDeferGivesUpAfterThreeAttempts() {
        let box = makeBox { _ in ("ok", 0, 0) }
        let now = Date()
        let f = PendingFollowup(createdAt: now, fireAt: now, intent: "问问结果")
        box.store.addFollowup(f, now: now)
        let id = box.store.state.followups[0].id
        XCTAssertNotNil(box.store.deferFollowup(id: id, now: now))
        XCTAssertNotNil(box.store.deferFollowup(id: id, now: now))
        XCTAssertNil(box.store.deferFollowup(id: id, now: now))   // 第 3 次失败 → 放弃
        XCTAssertTrue(box.store.state.followups.isEmpty)
    }

    func testStorePersistsAcrossRestart() {
        let box = makeBox { _ in ("ok", 0, 0) }
        let now = Date()
        box.store.addFollowup(PendingFollowup(createdAt: now, fireAt: now.addingTimeInterval(600),
                                              intent: "重启后还在吗", notifyText: "还在哦"), now: now)
        box.store.noteProactiveSent(now)
        // 用同一个目录与 suite 重建：状态与配置都应恢复
        let reopened = ProactiveStore(directory: box.directory, defaults: box.defaults)
        XCTAssertEqual(reopened.state.followups.first?.intent, "重启后还在吗")
        XCTAssertEqual(reopened.state.followups.first?.notifyText, "还在哦")
        // ISO8601 只存到秒，精确相等会因毫秒截断抖动，用区间断言
        XCTAssertNotNil(reopened.lastProactiveAt)
        XCTAssertLessThan(abs(reopened.lastProactiveAt!.timeIntervalSince(now)), 1)
        // 免打扰配置也是持久化的
        XCTAssertEqual(reopened.config.quietStartMinute, 0)
        XCTAssertEqual(reopened.config.quietEndMinute, 0)
    }

    // MARK: Engine · 到点生成闭环

    func testEngineFiresDueFollowupIntoChatMemoryAndClearsNotification() async {
        let box = makeBox { _ in ("面完啦？跟俺说说～", 120, 30) }
        let now = Date()
        box.store.addFollowup(PendingFollowup(createdAt: now.addingTimeInterval(-3600),
                                              fireAt: now.addingTimeInterval(-60),
                                              intent: "问问面试结果"), now: now)
        let id = box.store.state.followups[0].id
        let fired = await box.engine.fireDueFollowupIfNeeded()

        XCTAssertTrue(fired)
        // 闭环：进记忆（assistant 条目）+ 出气泡 + 移除闹铃与预约通知
        XCTAssertEqual(box.memory.record.entries.last?.role, "assistant")
        XCTAssertEqual(box.memory.record.entries.last?.content, "面完啦？跟俺说说～")
        XCTAssertEqual(box.engine.lastArrival?.text, "面完啦？跟俺说说～")
        XCTAssertTrue(box.store.state.followups.isEmpty)
        XCTAssertEqual(box.poster.removed, [SystemNotificationPoster.followupPrefix + id.uuidString])
        // token 计入用量
        let day = box.usage.recentDays(1).first?.usage
        XCTAssertEqual(day?.promptTokens, 120)
        XCTAssertEqual(day?.completionTokens, 30)
        // 冷却起点已记
        XCTAssertNotNil(box.store.lastProactiveAt)
    }

    func testEngineSkipRemovesFollowupWithoutMessage() async {
        let box = makeBox { _ in ("（skip）", 100, 1) }
        let now = Date()
        box.store.addFollowup(PendingFollowup(createdAt: now, fireAt: now.addingTimeInterval(-30),
                                              intent: "已经聊过了的事"), now: now)
        let fired = await box.engine.fireDueFollowupIfNeeded()

        XCTAssertFalse(fired)
        XCTAssertNil(box.engine.lastArrival)
        XCTAssertTrue(box.store.state.followups.isEmpty)      // 视为已兑现，不再催
        XCTAssertTrue(box.memory.record.entries.isEmpty)      // 不进记忆
    }

    func testEngineFailureDefersThenGivesUp() async {
        var calls = 0
        let box = makeBox { _ in
            calls += 1
            throw ToolLoopError(message: "网络断了")
        }
        let now = Date()
        box.store.addFollowup(PendingFollowup(createdAt: now, fireAt: now.addingTimeInterval(-60),
                                              intent: "会失败的闹铃"), now: now)
        let id = box.store.state.followups[0].id

        _ = await box.engine.fireDueFollowupIfNeeded()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(box.store.state.followups.count, 1)
        XCTAssertEqual(box.store.state.followups[0].attempts, 1)
        XCTAssertGreaterThan(box.store.state.followups[0].fireAt, now)   // 推迟了

        // 推迟 10 分钟后未到期，不重写 fireAt 就不会再触发
        _ = await box.engine.fireDueFollowupIfNeeded()
        XCTAssertEqual(calls, 1)

        // 拨回「已到期」模拟重试到期；两次到期重试（attempts 2→3）后放弃
        box.store.overrideFireAtForTesting(id: id, to: now.addingTimeInterval(-1))
        _ = await box.engine.fireDueFollowupIfNeeded()
        XCTAssertEqual(calls, 2)
        box.store.overrideFireAtForTesting(id: id, to: now.addingTimeInterval(-1))
        _ = await box.engine.fireDueFollowupIfNeeded()
        XCTAssertEqual(calls, 3)    // 第 3 次请求发出后放弃
        XCTAssertTrue(box.store.state.followups.isEmpty)
        XCTAssertEqual(box.poster.removed, [SystemNotificationPoster.followupPrefix + id.uuidString])
    }

    func testEngineBusySuppressesAndUserTurnCancelsFollowups() async {
        let box = makeBox { _ in ("好的", 10, 5) }
        let now = Date()
        box.store.addFollowup(PendingFollowup(createdAt: now, fireAt: now.addingTimeInterval(-60),
                                              intent: "对话期间该压住"), now: now)

        // 对话开始：挂起闹铃全部取消（闭环提前完成）+ 预约通知清空
        await box.engine.beginUserTurn()
        XCTAssertTrue(box.store.state.followups.isEmpty)
        XCTAssertEqual(box.poster.removeAllCount, 1)
        let firedWhileBusy = await box.engine.fireDueFollowupIfNeeded()
        XCTAssertFalse(firedWhileBusy)   // busy 中不触发

        box.engine.endUserTurn()
        XCTAssertFalse(box.engine.conversationBusy)
    }

    func testEngineDisabledBlocksEverything() async {
        let box = makeBox { _ in ("不该出现", 0, 0) }
        box.store.config.enabled = false
        let now = Date()
        box.store.addFollowup(PendingFollowup(createdAt: now, fireAt: now.addingTimeInterval(-60),
                                              intent: "总开关关了"), now: now)
        let fired = await box.engine.fireDueFollowupIfNeeded()
        XCTAssertFalse(fired)
        XCTAssertEqual(box.store.state.followups.count, 1)   // 不生成也不误删（applyConfig 才清）
        XCTAssertNil(box.engine.lastArrival)
    }

    // MARK: Tools

    func testFollowupSetToolValidatesAndStores() async {
        let box = makeBox { _ in ("ok", 0, 0) }
        let tool = FollowupSetTool(store: box.store)
        let good = await tool.run(argumentsJSON: #"{"minutes": 90, "intent": "问问开会结果", "notify": "开完会了嘛？"}"#)
        XCTAssertTrue(good.contains("记下了"))
        let stored = box.store.state.followups.first
        XCTAssertEqual(stored?.intent, "问问开会结果")
        XCTAssertEqual(stored?.notifyText, "开完会了嘛？")
        let expected = Date().timeIntervalSince1970
        let fireIn = stored!.fireAt.timeIntervalSince1970 - expected
        XCTAssertEqual(fireIn, 90 * 60, accuracy: 30)

        // minutes 越界 / intent 缺失
        let tooShort = await tool.run(argumentsJSON: #"{"minutes": 1, "intent": "太短"}"#)
        XCTAssertTrue(tooShort.contains("error"))
        let noIntent = await tool.run(argumentsJSON: #"{"minutes": 30}"#)
        XCTAssertTrue(noIntent.contains("error"))
        XCTAssertEqual(box.store.state.followups.count, 1)

        // 总开关关闭 → 明确报错
        box.store.config.enabled = false
        let disabled = await tool.run(argumentsJSON: #"{"minutes": 30, "intent": "关了"}"#)
        XCTAssertTrue(disabled.contains("没有开启"))
        box.store.config.enabled = true
        let cancel = await FollowupCancelTool(store: box.store).run(argumentsJSON: "{}")
        XCTAssertTrue(cancel.contains("已取消"))
    }
}
