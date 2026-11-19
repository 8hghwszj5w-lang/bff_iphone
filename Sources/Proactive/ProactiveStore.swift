import Foundation
import Combine

// MARK: - 主动消息插件：存储层
//
// 两类数据，两套持久化（沿用项目里「UserDefaults 存配置、Documents 存状态」的惯例）：
// · 配置 ProactiveConfig → UserDefaults 单 key JSON（didSet 即存，设置页改动即时生效）
// · 运行状态 SavedState（挂起闹铃 + 上次主动消息时间）→ Documents/proactive/state.json
//   原子写（tmp+rename 等价，.atomic 直接支持），坏文件留档不阻塞启动，
//   和 MemoryStore / UsageStore 同一套策略。
//
// 挂起闹铃为什么必须落盘：闹铃是「n 时间后」的承诺，App 被杀重启后
// 依然要兑现（下次启动 catch-up），所以不能只放在内存里。

@MainActor
final class ProactiveStore: ObservableObject {
    /// 运行状态（闹铃是承诺，必须落盘；重启后依然兑现）
    struct SavedState: Codable {
        var followups: [PendingFollowup] = []
        var lastProactiveAt: Date? = nil
    }

    /// 挂起闹铃上限：防止模型连环 followup_set 把通知栏刷爆
    static let maxFollowups = 5

    @Published var config: ProactiveConfig {
        didSet { saveConfig() }
    }
    @Published private(set) var state: SavedState {
        didSet { saveState() }
    }

    private let defaults: UserDefaults
    private let fileURL: URL

    /// - directory: nil 用 App Documents/proactive/；测试传临时目录
    /// - defaults:  测试传 UserDefaults(suiteName:) 隔离沙箱
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let directory {
            self.fileURL = directory.appendingPathComponent("state.json", isDirectory: false)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = docs.appendingPathComponent("proactive", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        if let data = defaults.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(ProactiveConfig.self, from: data) {
            config = decoded
        } else {
            config = ProactiveConfig()
        }
        state = Self.loadState(from: fileURL)
    }

    static let configKey = "proactive.config.v1"

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.configKey)
        }
    }

    private static func loadState(from url: URL) -> SavedState {
        guard let data = try? Data(contentsOf: url) else { return SavedState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(SavedState.self, from: data) {
            return decoded
        }
        // 坏文件留档不阻塞启动（同 MemoryStore 的损坏恢复策略）
        let backup = url.deletingPathExtension()
            .appendingPathExtension("\(UUID().uuidString).corrupt.json")
        try? FileManager.default.moveItem(at: url, to: backup)
        return SavedState()
    }

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: 挂起闹铃

    /// 添加一条闹铃。返回给模型看的确认/失败说明（中文，沿用日程工具的口吻）。
    @discardableResult
    func addFollowup(_ followup: PendingFollowup, now: Date = Date()) -> String {
        var f = followup
        // 排队超限或完全相同意图的重复设置：温和拒绝，让模型自己换说法
        if state.followups.contains(where: { $0.intent == f.intent }) {
            return "这件事已经记下了，不用重复记。"
        }
        guard state.followups.count < Self.maxFollowups else {
            return "挂着的事太多了（最多 \(Self.maxFollowups) 件），先别记新的，或者用 followup_cancel 取销一件。"
        }
        f.createdAt = now
        state.followups.append(f)
        return "记下了：约 \(Int(f.fireAt.timeIntervalSince(now) / 60)) 分钟后主动找他聊聊（\(f.intent)）。"
            + "到点你会自己开口，不用等他回复；回复里别提到这个工具。"
    }

    @discardableResult
    func cancelAllFollowups() -> Int {
        let n = state.followups.count
        if n > 0 { state.followups = [] }
        return n
    }

    func cancelFollowup(id: UUID) {
        state.followups.removeAll { $0.id == id }
    }

    /// 到点该触发的闹铃（已按免打扰顺延后的时刻计算；免打扰时段内什么都不触发）。
    /// 生成失败重试过的（fireAt 被推迟）也由这里统一判到期。
    func dueFollowups(now: Date, calendar: Calendar = .current) -> [PendingFollowup] {
        guard !ProactivePolicy.isInQuietHours(now, config: config, calendar: calendar) else { return [] }
        return state.followups
            .filter { ProactivePolicy.effectiveFireDate($0.fireAt, config: config, calendar: calendar) <= now }
            .sorted { $0.fireAt < $1.fireAt }
    }

    /// 生成失败：推迟重试。返回 false 表示已满 3 次放弃（闹铃移除）。
    /// - Returns: 仍需重试时的新 fireAt（已顺延 retryDelay 分钟）
    func deferFollowup(id: UUID, retryDelayMinutes: Int = 10, now: Date = Date()) -> Date? {
        guard let idx = state.followups.firstIndex(where: { $0.id == id }) else { return nil }
        state.followups[idx].attempts += 1
        if state.followups[idx].attempts >= 3 {
            state.followups.remove(at: idx)
            return nil
        }
        let newFire = now.addingTimeInterval(TimeInterval(retryDelayMinutes) * 60)
        state.followups[idx].fireAt = newFire
        return newFire
    }

    /// 测试钩子：把某条闹铃拨回「已到期」时刻（state 是 private(set)，离线测试
    /// 模拟「推迟重试后又到期」只能走这里；生产代码不使用）
    func overrideFireAtForTesting(id: UUID, to date: Date) {
        guard let idx = state.followups.firstIndex(where: { $0.id == id }) else { return }
        state.followups[idx].fireAt = date
    }

    // MARK: 主动消息节奏

    var lastProactiveAt: Date? { state.lastProactiveAt }

    func noteProactiveSent(_ date: Date = Date()) {
        state.lastProactiveAt = date
    }
}
