import Foundation
import SwiftUI

// MARK: - 设置（对应原项目 config/schema.js 的角色）

@MainActor
final class SettingsStore: ObservableObject {
    // AppStorage 是 View 的 DynamicProperty；放在 ObservableObject 内不会发布变更。
    // 保留原有 defaults key，同时让设置页及依赖这些设置的视图及时刷新。
    private let defaults: UserDefaults
    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: "settings.apiKey") } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "settings.baseURL") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "settings.model") } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: "settings.temperature") } }
    @Published var maxHistory: Int { didSet { defaults.set(maxHistory, forKey: "settings.maxHistory") } }
    @Published var autoSearch: Bool { didSet { defaults.set(autoSearch, forKey: "settings.autoSearch") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKey = defaults.string(forKey: "settings.apiKey") ?? ""
        baseURL = defaults.string(forKey: "settings.baseURL") ?? "https://api.deepseek.com/v1"
        model = defaults.string(forKey: "settings.model") ?? "deepseek-flash"
        temperature = defaults.object(forKey: "settings.temperature") as? Double ?? 0.8
        maxHistory = defaults.object(forKey: "settings.maxHistory") as? Int ?? 40
        autoSearch = defaults.object(forKey: "settings.autoSearch") as? Bool ?? true
    }
}

// MARK: - 人设（对应 bridge/persona.md，可在 App 内编辑）

@MainActor
final class PersonaStore: ObservableObject {
    static let defaultPersona = """
    你叫小深，是主人的数字分身助手，住在主人的 iPhone 里。

    性格：自然、亲近、有点俏皮，像认识多年的朋友。
    说话规则：
    - 用简短口语化的中文回答，别客套、别长篇大论；
    - 不确定的事直说不知道，或者用 web_search 工具查一下再答；
    - 记得主人告诉过你的事（长期记忆里有的），主动提起细节。
    """
    @Published var text: String = UserDefaults.standard.string(forKey: "persona.md") ?? defaultPersona

    func save() { UserDefaults.standard.set(text, forKey: "persona.md") }

    func reset() { text = Self.defaultPersona; save() }
}

// MARK: - 长期记忆（对应 src/store/memory.js：逐字窗口 + 滚动摘要 + 原子写）

struct MemoryRecord: Codable {
    struct Entry: Codable {
        var role: String
        var content: String
        var time: Date
    }
    var contact = "default"
    var summary = ""                 // 滚动摘要（老对话压缩后的长期记忆）
    var entries: [Entry] = []        // 逐字窗口
}

@MainActor
final class MemoryStore: ObservableObject {
    private let fileURL: URL
    @Published var record = MemoryRecord()

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("default.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // 与保存策略一致
        if let decoded = try? decoder.decode(MemoryRecord.self, from: data) {
            record = decoded
            return
        }
        // 坏文件留档不阻塞启动（对应原项目 atomic.js 的损坏恢复）
        let backup = fileURL.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).corrupt.json")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    /// 原子写：先写临时文件再 rename，防止写一半损坏
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            // .atomic 同时支持首次创建和替换；replaceItemAt 在目标不存在时会失败。
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func append(role: String, content: String, maxHistory: Int) {
        // 防止损坏/旧版本设置使 prefix/removeFirst 收到负数，且至少保留当前消息。
        let maxHistory = max(2, maxHistory)
        record.entries.append(.init(role: role, content: content, time: Date()))
        // 逐字窗口超限：把最老的一半压成摘要（滚动摘要）
        if record.entries.count > maxHistory {
            let old = record.entries.prefix(record.entries.count - maxHistory / 2)
            let digest = old.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
            record.summary = (record.summary + "\n" + digest)
                .split(separator: "\n").suffix(60).joined(separator: "\n")
            record.entries.removeFirst(record.entries.count - maxHistory / 2)
        }
        save()
    }

    /// 组装发给模型的上下文：system(人设+摘要) + 窗口
    func contextMessages(persona: String) -> [ChatMessage] {
        var sys = persona
        if !record.summary.isEmpty {
            sys += "\n\n【长期记忆（更早对话的摘要）】\n" + record.summary
        }
        var msgs = [ChatMessage.system(sys)]
        msgs += record.entries.map { $0.role == "user" ? .user($0.content) : .assistant($0.content) }
        return msgs
    }

    // MARK: 记忆管理支持（供「记忆管理」页使用）

    var fileByteSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    var relativePath: String { "Documents/memory/" + fileURL.lastPathComponent }

    /// 导出为可分享的 JSON 文本
    var exportText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func updateSummary(_ text: String) { record.summary = text; save() }

    func clearEntries() { record.entries = []; save() }

    func clearSummary() { record.summary = ""; save() }

    func removeEntries(at offsets: IndexSet) {
        record.entries.remove(atOffsets: offsets)
        save()
    }

    /// 管理界面最新消息在前，显示下标必须转换回存储下标。
    func removeEntriesInReverseOrder(at offsets: IndexSet) {
        let count = record.entries.count
        let originalOffsets = IndexSet(offsets.filter { $0 < count && $0 >= 0 }.map { count - 1 - $0 })
        removeEntries(at: originalOffsets)
    }

    func reset() { record = MemoryRecord(); save() }
}

// MARK: - 用量统计（对应 src/core/usage.js：token 用量归一化 + 落盘）

struct UsageStats: Codable {
    struct DayUsage: Codable {
        var promptTokens = 0
        var completionTokens = 0
        var messages = 0
        var total: Int { promptTokens + completionTokens }
    }
    var totalPromptTokens = 0
    var totalCompletionTokens = 0
    var totalMessages = 0
    var daily: [String: DayUsage] = [:]      // key: yyyy-MM-dd
    var firstUsed: Date?

    var totalTokens: Int { totalPromptTokens + totalCompletionTokens }
}

@MainActor
final class UsageStore: ObservableObject {
    private let fileURL: URL
    @Published var stats = UsageStats()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("usage.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(UsageStats.self, from: data) {
            stats = decoded
            return
        }
        // 坏文件留档不阻塞启动
        let backup = fileURL.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).corrupt.json")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    /// 原子写，和记忆存储同一套策略
    private func save() {
        if let data = try? JSONEncoder().encode(stats) {
            // .atomic 同时支持首次创建和替换；replaceItemAt 在目标不存在时会失败。
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func append(promptTokens: Int, completionTokens: Int) {
        let key = Self.dayKey(for: Date())
        var day = stats.daily[key] ?? UsageStats.DayUsage()
        day.promptTokens += promptTokens
        day.completionTokens += completionTokens
        day.messages += 1
        stats.daily[key] = day
        stats.totalPromptTokens += promptTokens
        stats.totalCompletionTokens += completionTokens
        stats.totalMessages += 1
        if stats.firstUsed == nil { stats.firstUsed = Date() }
        save()
    }

    static func dayKey(for date: Date) -> String {
        dayFormatter.timeZone = .current
        return dayFormatter.string(from: date)
    }

    /// 最近 n 天（含今天），从今天往回排
    func recentDays(_ n: Int = 7) -> [(date: String, usage: UsageStats.DayUsage)] {
        let now = Date()
        return (0..<max(0, n)).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = Self.dayKey(for: date)
            let usage = stats.daily[key] ?? UsageStats.DayUsage()
            return (key, usage)
        }
    }

    func reset() { stats = UsageStats(); save() }
}

// MARK: - 聊天背景（设置 → 聊天背景；纯色 / 渐变 / 相册自定义）

enum ChatBackgroundStyle: String, CaseIterable, Identifiable {
    case system, warm, mint, sakura, aurora, night, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "系统默认"
        case .warm: return "暖米色"
        case .mint: return "薄荷绿"
        case .sakura: return "樱花粉"
        case .aurora: return "极光渐变"
        case .night: return "静谧夜色"
        case .custom: return "自定义照片"
        }
    }
}

@MainActor
final class ChatBackgroundStore: ObservableObject {
    private let defaults: UserDefaults
    private let directory: URL
    @Published var styleRaw: String { didSet { defaults.set(styleRaw, forKey: "chat.bg.style") } }
    @Published var customFile: String { didSet { defaults.set(customFile, forKey: "chat.bg.customFile") } }
    @Published private(set) var imageRevision = 0

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        styleRaw = defaults.string(forKey: "chat.bg.style") ?? ChatBackgroundStyle.system.rawValue
        customFile = defaults.string(forKey: "chat.bg.customFile") ?? ""
    }

    var style: ChatBackgroundStyle { ChatBackgroundStyle(rawValue: styleRaw) ?? .system }

    private var customURL: URL { directory.appendingPathComponent("chat_bg.jpg") }
    private var originalURL: URL { directory.appendingPathComponent("chat_bg_original.jpg") }

    /// 相册选中的原图（未裁剪），保存后可反复重新裁剪
    func saveOriginalImage(_ data: Data) {
        try? data.write(to: originalURL, options: .atomic)
    }

    var hasOriginalImage: Bool {
        FileManager.default.fileExists(atPath: originalURL.path)
    }

    func loadOriginalImage() -> UIImage? {
        UIImage(contentsOfFile: originalURL.path)
    }

    /// 裁剪完成的图才是实际聊天背景
    func saveCroppedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        do {
            try data.write(to: customURL, options: .atomic)
            customFile = customURL.lastPathComponent
            styleRaw = ChatBackgroundStyle.custom.rawValue
            imageRevision += 1
        } catch {
            // 原子写失败时保留此前可用的背景及选择。
        }
    }

    func select(_ style: ChatBackgroundStyle) { styleRaw = style.rawValue }

    /// 保存相册选中的图片到 App 沙盒，并切到自定义背景
    func saveCustomImage(_ data: Data) {
        do {
            try data.write(to: customURL, options: .atomic)
            customFile = customURL.lastPathComponent
            styleRaw = ChatBackgroundStyle.custom.rawValue
            imageRevision += 1
        } catch {
            // 原子写失败时保留此前可用的背景及选择。
        }
    }

    func clearCustomImage() {
        try? FileManager.default.removeItem(at: customURL)
        try? FileManager.default.removeItem(at: originalURL)
        customFile = ""
        imageRevision += 1
        if style == .custom { styleRaw = ChatBackgroundStyle.system.rawValue }
    }
}
