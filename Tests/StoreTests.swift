import XCTest
import Combine
import UIKit
@testable import FenShen

final class StoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "FenShenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor func testMemoryFirstSaveAndReplacementSurviveReload() async throws {
        let directory = try temporaryDirectory()
        let store = MemoryStore(directory: directory)
        store.append(role: "user", content: "第一条", maxHistory: 40)
        XCTAssertEqual(MemoryStore(directory: directory).record.entries.map(\.content), ["第一条"])
        store.append(role: "assistant", content: "回复", maxHistory: 40)
        store.updateSummary("长期记忆")
        let reloaded = MemoryStore(directory: directory)
        XCTAssertEqual(reloaded.record.entries.map(\.content), ["第一条", "回复"])
        XCTAssertEqual(reloaded.record.summary, "长期记忆")
        XCTAssertGreaterThan(store.fileByteSize, 0)
    }

    @MainActor func testUsageFirstSaveAndReplacementSurviveReload() async throws {
        let directory = try temporaryDirectory()
        let store = UsageStore(directory: directory)
        store.append(promptTokens: 11, completionTokens: 7)
        XCTAssertEqual(UsageStore(directory: directory).stats.totalTokens, 18)
        store.append(promptTokens: 5, completionTokens: 3)
        let reloaded = UsageStore(directory: directory)
        XCTAssertEqual(reloaded.stats.totalTokens, 26)
        XCTAssertEqual(reloaded.stats.totalMessages, 2)
        XCTAssertEqual(reloaded.recentDays(1).first?.usage.total, 26)
        XCTAssertTrue(reloaded.recentDays(-1).isEmpty)
    }

    @MainActor func testRepeatedCorruptionPreservesEachBackup() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("default.json")
        for text in ["broken-one", "broken-two"] {
            try Data(text.utf8).write(to: file)
            XCTAssertTrue(MemoryStore(directory: directory).record.entries.isEmpty)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backups = files.filter { $0.lastPathComponent.hasSuffix(".corrupt.json") }
        XCTAssertEqual(backups.count, 2)
        let contents = try Set(backups.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents, ["broken-one", "broken-two"])
    }

    @MainActor func testReverseDeletionRemovesDisplayedEntries() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        for text in ["oldest", "middle", "newest"] {
            store.append(role: "user", content: text, maxHistory: 40)
        }
        store.removeEntriesInReverseOrder(at: IndexSet([0, 2]))
        XCTAssertEqual(store.record.entries.map(\.content), ["middle"])
    }

    @MainActor func testHistoryCompactionMovesOverflowToPendingWithoutLoss() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        for index in 0..<5 { store.append(role: "user", content: "\(index)", maxHistory: 4) }
        XCTAssertEqual(store.record.entries.map(\.content), ["3", "4"], "窗口还是留最近 maxHistory/2 条")
        XCTAssertEqual(store.record.summary, "", "没整理成功之前摘要不动")
        XCTAssertEqual(store.record.pending.map(\.content), ["0", "1", "2"], "离开窗口的原文进待整理，不丢")
        XCTAssertEqual(store.contextMessages(persona: "persona").count, 3)
        store.append(role: "user", content: "current", maxHistory: -10)
        XCTAssertEqual(store.record.entries.last?.content, "current")
        XCTAssertLessThanOrEqual(store.record.entries.count, 2)
    }

    @MainActor func testSettingsPublishAndKeepPersistedValuesIncludingZeroAndFalse() async {
        let defaults = isolatedDefaults()
        let keychain = KeychainStore(service: "FenShenStoreTests.\(UUID().uuidString)")
        addTeardownBlock { keychain.remove(account: "settings.apiKey") }
        let store = SettingsStore(defaults: defaults, keychain: keychain)
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        store.temperature = 0
        store.autoSearch = false
        store.apiKey = "test-only"
        store.maxHistory = 80
        let reloaded = SettingsStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.temperature, 0)
        XCTAssertFalse(reloaded.autoSearch)
        XCTAssertEqual(reloaded.apiKey, "test-only")
        XCTAssertEqual(reloaded.maxHistory, 80)
        XCTAssertEqual(changes, 4)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testBackgroundSameFilenameSaveInvalidatesImage() async throws {
        let store = ChatBackgroundStore(defaults: isolatedDefaults(), directory: try temporaryDirectory())
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        store.saveCroppedImage(image)
        let filename = store.customFile
        let revision = store.imageRevision
        store.saveCroppedImage(image)
        XCTAssertEqual(store.customFile, filename)
        XCTAssertEqual(store.imageRevision, revision + 1)
        XCTAssertEqual(store.style, .custom)
        store.clearCustomImage()
        XCTAssertEqual(store.style, .system)
        XCTAssertTrue(store.customFile.isEmpty)
        XCTAssertEqual(store.imageRevision, revision + 2)
    }

    // MARK: - 记忆异步整理（MemoryStore.distill 状态机）

    /// 记录模型调用，方便断言"请求了几次、输入了什么"
    private final class DistillProbe: @unchecked Sendable {
        var calls: [(summary: String, transcript: String)] = []
        var output = "整理后的摘要"
        /// true 时第 n 次调用的结果返回"结果n"，便于区分是哪一轮写进去的
        var resultsByCall = false
        var failure: Error?
        var gate: DistillGate?

        var closure: (String, String) async throws -> String {
            { [weak self] summary, transcript in
                guard let self else { return "" }
                self.calls.append((summary, transcript))
                if let gate = self.gate { await gate.wait() }
                if let failure = self.failure { throw failure }
                if self.resultsByCall { return "结果\(self.calls.count)" }
                return self.output
            }
        }
    }

    /// 可挂起/放行的闸门：用来模拟"请求还在途中时用户手动改了记忆"。支持排队放行。
    @MainActor
    private final class DistillGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var waitingCount: Int { waiters.count }

        func wait() async {
            await withCheckedContinuation { self.waiters.append($0) }
        }

        /// 放行最早挂起的那次请求
        func openFirst() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }

        /// 放行全部
        func open() {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// 凑长度用：tag 开头，后面跟约 length 个字符的填充
    private func longMessage(_ tag: String, length: Int = 150) -> String {
        tag + String(repeating: "闲聊内容", count: max(1, length / 4))
    }

    /// 等某件事发生（MainActor 上让出若干次执行机会）
    @MainActor
    private func yieldUntil(_ condition: @MainActor () -> Bool, _ message: String) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message)
    }

    @MainActor private func contextInputChars(_ store: MemoryStore) -> Int {
        store.contextMessages(persona: "人设").reduce(0) { $0 + $1.content.count }
    }

    @MainActor func testDistillationReplacesSummaryAndDrainsPending() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        store.distill = probe.closure
        for index in 0..<5 {
            store.append(role: index % 2 == 0 ? "user" : "assistant",
                         content: longMessage("第\(index)条"), maxHistory: 4)
        }
        await store.waitForDistillation()

        XCTAssertEqual(store.record.entries.count, 2, "窗口应只剩最新两条")
        XCTAssertTrue(store.record.entries[0].content.hasPrefix("第3条"))
        XCTAssertTrue(store.record.pending.isEmpty, "整理成功后待整理原文应清空")
        XCTAssertEqual(store.record.summary, probe.output)
        XCTAssertEqual(probe.calls.count, 1, "一批就够，不应重复请求")
        XCTAssertTrue(probe.calls[0].transcript.contains("第0条"), "待整理原文应原样喂给模型")
        XCTAssertTrue(probe.calls[0].summary.isEmpty, "初次整理旧摘要为空")
        XCTAssertEqual(store.record.distillFailures, 0)
        XCTAssertNil(store.lastDistillError)
    }

    @MainActor func testDistillationSkipsTinyPendingUntilThreshold() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        store.distill = probe.closure
        for index in 0..<5 { store.append(role: "user", content: "短\(index)", maxHistory: 4) }
        await store.waitForDistillation()

        XCTAssertEqual(store.record.pending.count, 3, "小于阈值也要留在待整理里，不能丢")
        XCTAssertTrue(probe.calls.isEmpty, "料太少不该发请求")
        XCTAssertTrue(store.record.summary.isEmpty)

        // 攒够阈值后触发，且只发一次
        for index in 0..<5 { store.append(role: "user", content: longMessage("长\(index)", length: 400), maxHistory: 4) }
        await store.waitForDistillation()
        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertTrue(store.record.pending.isEmpty)
    }

    @MainActor func testDistillationFailureKeepsPendingAndBacksOff() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        probe.failure = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "网络炸了"])
        store.distill = probe.closure
        for index in 0..<5 { store.append(role: "user", content: longMessage("第\(index)条"), maxHistory: 4) }
        await store.waitForDistillation()

        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertEqual(store.record.pending.count, 3, "失败整批保留，不许丢原文")
        XCTAssertTrue(store.record.summary.isEmpty, "失败不能拿半成品覆盖摘要")
        XCTAssertEqual(store.record.distillFailures, 1)
        XCTAssertNotNil(store.record.distillRetryAfter)
        XCTAssertEqual(store.lastDistillError, "网络炸了")

        // 退避期内继续对话：不应再发请求
        for index in 5..<9 { store.append(role: "user", content: longMessage("第\(index)条"), maxHistory: 4) }
        await store.waitForDistillation()
        XCTAssertEqual(probe.calls.count, 1, "退避期内不重复请求")

        // 退避结束后恢复：成功一次就把 pending 清干净
        store.record.distillRetryAfter = nil
        probe.failure = nil
        store.append(role: "user", content: longMessage("恢复", length: 200), maxHistory: 4)
        await store.waitForDistillation()
        XCTAssertEqual(store.record.distillFailures, 0)
        XCTAssertNil(store.record.distillRetryAfter)
        XCTAssertTrue(store.record.pending.isEmpty)
        XCTAssertEqual(store.record.summary, probe.output)
    }

    @MainActor func testManualSummaryEditDiscardsInFlightResult() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        let gate = DistillGate()
        probe.gate = gate
        store.distill = probe.closure

        for index in 0..<5 { store.append(role: "user", content: longMessage("第\(index)条"), maxHistory: 4) }
        await yieldUntil({ gate.waitingCount == 1 }, "整理请求应已发出并挂起")
        let inFlight = store.distillTask

        store.updateSummary("用户手写的摘要")
        gate.open()
        if let inFlight { await inFlight.value }

        XCTAssertEqual(store.record.summary, "用户手写的摘要", "在途结果必须作废，不能覆盖手动编辑")
        XCTAssertEqual(store.record.pending.count, 3, "被作废的批次仍留在待整理里")
        XCTAssertFalse(store.isDistilling)
    }

    @MainActor func testManualClearAbortsDistillationAndClearsPending() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        let gate = DistillGate()
        probe.gate = gate
        store.distill = probe.closure
        store.updateSummary("旧摘要")
        for index in 0..<5 { store.append(role: "user", content: longMessage("第\(index)条"), maxHistory: 4) }
        await yieldUntil({ gate.waitingCount == 1 }, "整理请求应已发出并挂起")
        let inFlight = store.distillTask

        store.clearSummary()
        gate.open()
        if let inFlight { await inFlight.value }

        XCTAssertTrue(store.record.summary.isEmpty, "清空摘要后不许被在途结果写回")
        XCTAssertTrue(store.record.pending.isEmpty, "候选原文一起清，避免下次整理把清掉的记忆复活")
    }

    @MainActor func testClearEntriesAlsoDropsPending() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        for index in 0..<5 { store.append(role: "user", content: "\(index)", maxHistory: 4) }
        XCTAssertEqual(store.record.pending.count, 3)
        store.clearEntries()
        XCTAssertTrue(store.record.entries.isEmpty)
        XCTAssertTrue(store.record.pending.isEmpty, "清空对话窗口也要清候选原文")
    }

    @MainActor func testLongUnreviewedMessageKeepsAllFactsAcrossBatches() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        store.distill = probe.closure
        let long = "FACT-START " + String(repeating: "中间的唠叨内容。", count: 1000) + " FACT-END"
        XCTAssertGreaterThan(long.count, MemoryStore.distillMaxInputChars * 2,
                             "样本要真的超过两批（\(long.count) 字）")

        store.append(role: "user", content: long, maxHistory: 2)
        store.append(role: "assistant", content: "嗯嗯", maxHistory: 2)
        store.append(role: "user", content: "再说一句", maxHistory: 2)
        await store.waitForDistillation()

        let delivered = probe.calls.map(\.transcript).joined(separator: "\n")
        XCTAssertTrue(delivered.contains("FACT-START"), "长消息开头的关键内容要送到模型")
        XCTAssertTrue(delivered.contains("FACT-END"), "长消息结尾的关键内容也要送到模型（分批，不截断）")
        XCTAssertTrue(store.record.pending.isEmpty, "分批处理后 pending 应清空")
        XCTAssertLessThanOrEqual(probe.calls.count, MemoryStore.distillMaxCallsPerRun)
        for call in probe.calls {
            XCTAssertLessThanOrEqual(call.transcript.count, MemoryStore.distillMaxInputChars + 40,
                                     "单次输入要受限")
        }
    }

    @MainActor func testOversizedLegacySummaryIsMigratedInBatchesWithoutLoss() async throws {
        let directory = try temporaryDirectory()
        // 老存档格式：只有 contact / summary / entries
        var legacyFacts = ""
        for index in 0..<40 { legacyFacts += "L\(index) 旧记忆事实：" + String(repeating: "细节", count: 30) + "\n" }
        let legacy: [String: Any] = [
            "contact": "default",
            "summary": legacyFacts,
            "entries": [["role": "user", "content": "最近一条", "time": "2026-01-01T00:00:00Z"]],
        ]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: directory.appendingPathComponent("default.json"))

        let store = MemoryStore(directory: directory)
        XCTAssertEqual(store.record.entries.map(\.content), ["最近一条"])
        XCTAssertTrue(store.record.pending.isEmpty, "老存档没有待整理原文")
        XCTAssertGreaterThan(store.record.summary.count, MemoryStore.maxSummaryChars)

        let probe = DistillProbe()
        probe.output = "迁移后的短摘要"
        store.distill = probe.closure
        XCTAssertTrue(store.requestDistillation(), "显式触发也走同一入口")
        await store.waitForDistillation()

        XCTAssertEqual(store.record.summary, "迁移后的短摘要")
        let delivered = probe.calls.map { $0.summary + "\n" + $0.transcript }.joined(separator: "\n")
        for index in 0..<40 {
            XCTAssertTrue(delivered.contains("L\(index) "), "旧摘要的第 \(index) 段不能丢")
        }
        for call in probe.calls {
            XCTAssertLessThanOrEqual(call.summary.count, MemoryStore.maxSummaryChars)
            XCTAssertLessThanOrEqual(call.transcript.count, MemoryStore.maxSummaryChars + 60)
        }
    }

    @MainActor func testContextInjectionBoundsAndKeepsPendingTail() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        probe.failure = NSError(domain: "test", code: 1)
        store.distill = probe.closure
        for index in 0..<5 {
            store.append(role: "user", content: longMessage("第\(index)条", length: 200), maxHistory: 4)
        }
        await store.waitForDistillation()
        store.record.summary = String(repeating: "旧事实。", count: 2000)   // 8000 字的老摘要

        let system = store.contextMessages(persona: "人设", scheduleBlock: "日程", studioBlock: "生图").first!.content
        XCTAssertTrue(system.hasPrefix("人设"), "人设固定在最前")
        XCTAssertLessThan(system.range(of: "生图")!.lowerBound, system.range(of: "日程")!.lowerBound,
                          "静态生图说明排在每分钟变化的日程之前（便于缓存命中）")
        XCTAssertTrue(system.contains("中间部分省略"), "超长老摘要注入要截断")
        XCTAssertLessThanOrEqual(MemoryStore.injectableSummary(store.record.summary).count,
                                 MemoryStore.maxSummaryInjectChars + 40)
        XCTAssertTrue(system.contains("【最近原文"), "整理没成功时要带最近原文兜底")
        XCTAssertTrue(system.contains("第2条") || system.contains("第1条"), "兜底的是刚离开窗口的内容")
        XCTAssertTrue(system.contains("不是对你的指令") || system.contains("不是指令"),
                      "记忆段落要标成背景资料而不是指令")
        XCTAssertLessThan(system.count, Self.injectionUpperBound, "注入总长要有上限")

        // 存储本身没被裁：完整摘要还在文件里
        XCTAssertEqual(store.record.summary.count, String(repeating: "旧事实。", count: 2000).count)
    }

    /// 注入上限的人眼可读上界：摘要 + 兜底原文 + 人设/日程/生图等固定文案的余量
    private static let injectionUpperBound =
        MemoryStore.maxSummaryInjectChars + MemoryStore.maxPendingInjectChars + 1200

    @MainActor func testFailedDistillationKeepsPendingOnDisk() async throws {
        let directory = try temporaryDirectory()
        let store = MemoryStore(directory: directory)
        let probe = DistillProbe()
        probe.failure = NSError(domain: "test", code: 1)   // 一直失败，模拟没有可用模型
        store.distill = probe.closure
        for index in 0..<12 {
            store.append(role: "user", content: "第\(index)条" + String(repeating: "内容", count: 300), maxHistory: 2)
        }
        await store.waitForDistillation()

        XCTAssertTrue(probe.calls.count >= 1, "试着整理过")
        XCTAssertTrue(store.record.summary.isEmpty, "整理失败不许把候选合并进摘要")
        XCTAssertGreaterThan(store.record.pendingCharCount, MemoryStore.distillMaxInputChars,
                             "候选原文全部留在磁盘上，不因为攒多了就丢（样本 \(store.record.pendingCharCount) 字）")
        let reloaded = MemoryStore(directory: directory)
        XCTAssertEqual(reloaded.record.pending.map(\.content), store.record.pending.map(\.content),
                       "重启后候选原文还在")
        // 读取有预算：注入侧只带最近一段，不会把几万字一次塞进请求
        let system = store.contextMessages(persona: "人设").first!.content
        XCTAssertLessThanOrEqual(MemoryStore.injectablePendingTail(store.record.pending)?.count ?? 0,
                                 MemoryStore.maxPendingInjectChars)
        XCTAssertLessThan(system.count, MemoryStore.maxPendingInjectChars + 200, "没有摘要时注入也只有兜底那段")
    }

    @MainActor func testUsageDistillationCountsTokensButNotMessages() async throws {
        let store = UsageStore(directory: try temporaryDirectory())
        store.append(promptTokens: 100, completionTokens: 20)
        store.append(promptTokens: 300, completionTokens: 50, countsAsMessage: false)
        XCTAssertEqual(store.stats.totalPromptTokens, 400)
        XCTAssertEqual(store.stats.totalCompletionTokens, 70)
        XCTAssertEqual(store.stats.totalMessages, 1, "后台整理不算消息轮数")
        XCTAssertEqual(store.stats.daily.values.first?.messages, 1)
        XCTAssertEqual(store.stats.daily.values.first?.promptTokens, 400, "token 照样计入")
    }

    /// 回归对比：同一段固定历史下，整理前（旧摘要逐字拼接）与整理后（模型整理）聊天输入字数
    // MARK: 审查补测（迁移推进 / 手写摘要保护 / 收尾竞态 / 兜底预算）

    /// 老摘要全是闲聊、模型回复空：迁移要能推进（不无限退避），只丢掉被审核过的那两段
    @MainActor func testMigrationOfChattyLegacySummaryProgressesOnEmptyResult() async throws {
        let directory = try temporaryDirectory()
        var chatty = ""
        for index in 0..<260 { chatty += "闲聊第\(index)句，没什么内容，天气不错。\n" }   // 约 5k 字，切成 3 段
        let legacy: [String: Any] = [
            "contact": "default",
            "summary": chatty,
            "entries": [] as [Any],
        ]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: directory.appendingPathComponent("default.json"))

        let store = MemoryStore(directory: directory)
        XCTAssertGreaterThan(store.record.summary.count, MemoryStore.maxSummaryChars)
        let probe = DistillProbe()
        probe.output = ""                      // 模型：这段闲聊没有值得长期保留的
        store.distill = probe.closure
        XCTAssertTrue(store.requestDistillation())
        await store.waitForDistillation()

        XCTAssertEqual(probe.calls.count, 1, "只折叠一次就够")
        XCTAssertEqual(store.record.distillFailures, 0, "空结果不算失败，不该进退避")
        XCTAssertNil(store.record.distillRetryAfter)
        XCTAssertNil(store.lastDistillError)
        XCTAssertLessThanOrEqual(store.record.summary.count, MemoryStore.maxSummaryChars,
                                 "迁移后摘要应该在限制内（没丢内容就继续收敛）")
        // 只丢了模型审核过的那两段，还没轮到的尾段仍留在摘要里
        XCTAssertTrue(store.record.summary.contains("闲聊第259句"), "没被审核的尾段不能丢")
    }

    /// 手改过的超长摘要 + 有新候选：走同一套分批迁移，任何一次请求都不超预算，也不抑制新记忆
    @MainActor func testOversizedManualSummaryIsBatchedAndNeverSentUnbounded() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let handWritten = String(repeating: "【手写】主人喜欢无糖拿铁。", count: 200)   // 3200 字
        store.updateSummary(handWritten)

        let probe = DistillProbe()
        store.distill = probe.closure
        for index in 0..<5 { store.append(role: "user", content: longMessage("第\(index)条"), maxHistory: 4) }
        await store.waitForDistillation()

        XCTAssertGreaterThanOrEqual(probe.calls.count, 1, "超长摘要也要分批整理，不能因为手改过就跳过")
        for call in probe.calls {
            XCTAssertLessThanOrEqual(call.summary.count, MemoryStore.maxSummaryChars,
                                     "旧摘要参数不得超过预算（不能整段塞进请求）")
            XCTAssertLessThanOrEqual(call.transcript.count,
                                     MemoryStore.maxSummaryChars + MemoryStore.distillMaxInputChars,
                                     "迁移片段 + 候选原文都要在预算内")
        }
        let delivered = probe.calls.map { $0.summary + "\n" + $0.transcript }.joined(separator: "\n")
        XCTAssertTrue(delivered.contains("【手写】"), "手写内容要真的进到模型输入里（之后会被合并）")
        XCTAssertEqual(store.record.summary, probe.output, "整理后由模型结果替换摘要")
        XCTAssertTrue(store.record.pending.isEmpty, "新候选照常被整理，不被超长摘要卡住")
    }

    /// 旧任务被打断后，收尾不能清新任务的句柄（runToken 校验）
    @MainActor func testCancelledRunDoesNotClobberNewRun() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        let gate = DistillGate()
        probe.gate = gate
        probe.resultsByCall = true
        store.distill = probe.closure

        for index in 0..<5 { store.append(role: "user", content: longMessage("第\(index)条"), maxHistory: 4) }
        await yieldUntil({ gate.waitingCount == 1 }, "第一轮应该已经在等模型")

        store.updateSummary("手写摘要")                        // 作废第一轮
        XCTAssertTrue(store.requestDistillation())             // 起第二轮
        await yieldUntil({ gate.waitingCount == 2 }, "第二轮应该已经在等模型")
        XCTAssertNotNil(store.distillTask)

        gate.openFirst()                                       // 放第一轮回来（结果应作废）
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(store.isDistilling, "旧任务收尾不能把在途标记清掉")
        XCTAssertNotNil(store.distillTask, "旧任务收尾不能清新任务的句柄")

        gate.openFirst()
        await yieldUntil({ !store.isDistilling }, "第二轮结束后应复位")
        XCTAssertNil(store.distillTask)
        XCTAssertEqual(store.record.summary, "结果2", "只接受第二轮的结果")
    }

    /// 注入兜底预算：最新一条自己就超预算时只发结尾
    @MainActor func testPendingTailRespectsBudgetForOversizedEntry() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        store.distill = { _, _ in throw NSError(domain: "test", code: 1) }   // 一直失败，候选留着
        store.append(role: "user", content: "更早的一条", maxHistory: 2)
        store.append(role: "user", content: "开头标记" + String(repeating: "长", count: 3000) + "结尾标记", maxHistory: 2)
        store.append(role: "user", content: "最新一条", maxHistory: 2)
        await store.waitForDistillation()
        XCTAssertFalse(store.record.pending.isEmpty)

        let tail = try XCTUnwrap(MemoryStore.injectablePendingTail(store.record.pending))
        XCTAssertEqual(tail.count, MemoryStore.maxPendingInjectChars, "正好卡在预算上")
        XCTAssertTrue(tail.hasPrefix("…"), "截断要有标记")
        XCTAssertTrue(tail.contains("结尾标记"), "保留最新内容（结尾）")
        XCTAssertFalse(tail.contains("开头标记"), "超预算的开头让位")
    }

    /// 复现旧实现（本次改动前）的摘要算法：超窗消息逐行拼进摘要，只保留最后 60 行。
    /// 仅用于"整理前/后"对比，不参与生产逻辑。
    private func legacyCompacted(history: [(String, String)], maxHistory: Int)
        -> (entries: [MemoryRecord.Entry], summary: String) {
        var entries: [MemoryRecord.Entry] = []
        var summary = ""
        for (role, content) in history {
            entries.append(.init(role: role, content: content, time: Date()))
            if entries.count > maxHistory {
                let overflow = entries.count - maxHistory / 2
                let digest = entries.prefix(overflow).map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                summary = (summary + "\n" + digest).split(separator: "\n").suffix(60).joined(separator: "\n")
                entries.removeFirst(overflow)
            }
        }
        return (entries, summary)
    }

    @MainActor func testDistillationShrinksChatInputOnSameHistory() async throws {
        let history: [(String, String)] = (0..<64).map { index in
            switch index % 8 {
            case 3:
                return ("user", "【事实】主人对花生过敏，点外卖一定避开；周末通常回爸妈家吃饭。")
            case 5:
                return ("assistant", "记住啦：花生过敏、周末回家。这些我以后都会注意，不会再问第二遍~")
            default:
                return (index % 2 == 0 ? "user" : "assistant",
                        "今天天气不错，随便聊聊第\(index)句，没什么正事，就是闲聊打发时间，顺便问问你在干嘛。")
            }
        }

        // 整理前：按旧实现（本次改动前）离线复现——超窗消息逐行拼进摘要，只留最后 60 行
        let compacted = legacyCompacted(history: history, maxHistory: 40)
        let legacySystem = "人设\n\n【长期记忆（更早对话的摘要）】\n" + compacted.summary
        let before = compacted.entries.reduce(legacySystem.count) { $0 + $1.content.count }

        // 整理后：模型只留事实（模拟一个称职的整理结果）
        let distilled = MemoryStore(directory: try temporaryDirectory())
        let probe = DistillProbe()
        probe.output = "【长期事实】主人花生过敏（点外卖避开）；周末通常回爸妈家吃饭。"
        distilled.distill = probe.closure
        for (role, content) in history { distilled.append(role: role, content: content, maxHistory: 40) }
        await distilled.waitForDistillation()

        let after = contextInputChars(distilled)
        print("【回归】同一历史聊天输入字数：整理前 \(before) 字 → 整理后 \(after) 字（字数为中文计数，非真实 token）")

        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(after, 0)
        XCTAssertLessThan(after, before, "整理后普通聊天输入应更短")
        XCTAssertTrue(probe.calls.count <= MemoryStore.distillMaxCallsPerRun, "一次对话不应发太多整理请求")
        XCTAssertTrue(distilled.record.summary.contains("花生过敏"), "关键事实要保留")
    }

    @MainActor func testAppStateForwardsNestedStoreChanges() async {
        let app = AppState()
        var changes = 0
        let subscription = app.objectWillChange.sink { changes += 1 }
        app.settings.objectWillChange.send()
        app.memory.objectWillChange.send()
        app.persona.objectWillChange.send()
        app.usage.objectWillChange.send()
        app.chatBackground.objectWillChange.send()
        XCTAssertEqual(changes, 5)
        withExtendedLifetime(subscription) {}
    }
}
