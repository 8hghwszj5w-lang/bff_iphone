import Foundation
import SwiftUI

// MARK: - 设置（对应原项目 config/schema.js 的角色）
//
// 改动须知：
// · 每个字段对应一个 UserDefaults key（见 didSet），改 key 名会导致老用户设置丢失；
// · init 里的默认值只在「从未写过该 key」时生效——想让老安装也吃到新默认值，
//   要么换 key 名，要么加版本迁移逻辑；
// · 字段被谁消费：apiKey/baseURL/model → DeepSeekClient（调 API）；
//   temperature → 请求体；maxHistory → MemoryStore.append（窗口压缩阈值）；
//   autoSearch → Pipeline.handle（是否给模型声明 web_search 工具）。
// · 想加新设置项：照下面三步——声明 @Published + didSet、init 读默认值、
//   SettingsView 里加一行控件。

@MainActor
final class SettingsStore: ObservableObject {
    // AppStorage 是 View 的 DynamicProperty；放在 ObservableObject 内不会发布变更。
    // 保留原有 defaults key，同时让设置页及依赖这些设置的视图及时刷新。
    private let defaults: UserDefaults
    /// API Key 属于敏感凭据：存 Keychain（见 Sources/Call/KeychainStore.swift），
    /// 不进 UserDefaults / 不硬编码。首次启动自动把 UserDefaults 里的旧 key 迁移过来。
    private let keychain: KeychainStore
    @Published var apiKey: String {
        didSet {
            // Keychain 写失败（极端沙盒情况）退回 UserDefaults，宁可降级也不丢 Key
            if (try? keychain.set(apiKey, account: "settings.apiKey")) != nil {
                defaults.removeObject(forKey: "settings.apiKey")   // 迁移后从明文存储删除
            } else {
                defaults.set(apiKey, forKey: "settings.apiKey")
            }
        }
    }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "settings.baseURL") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "settings.model") } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: "settings.temperature") } }
    @Published var maxHistory: Int { didSet { defaults.set(maxHistory, forKey: "settings.maxHistory") } }
    @Published var autoSearch: Bool { didSet { defaults.set(autoSearch, forKey: "settings.autoSearch") } }

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        // Keychain 优先，其次迁移 UserDefaults 里的旧值，最后空串
        if let fromKeychain = keychain.string(account: "settings.apiKey") {
            apiKey = fromKeychain
        } else if let legacy = defaults.string(forKey: "settings.apiKey"), !legacy.isEmpty {
            apiKey = legacy
            // 迁移：写进 Keychain 并从 UserDefaults 删除（didSet 会做这两件事）
            if (try? keychain.set(legacy, account: "settings.apiKey")) != nil {
                defaults.removeObject(forKey: "settings.apiKey")
            }
        } else {
            apiKey = ""
        }
        baseURL = defaults.string(forKey: "settings.baseURL") ?? "https://api.deepseek.com/v1"
        model = defaults.string(forKey: "settings.model") ?? "deepseek-flash"
        temperature = defaults.object(forKey: "settings.temperature") as? Double ?? 0.8
        maxHistory = defaults.object(forKey: "settings.maxHistory") as? Int ?? 40
        autoSearch = defaults.object(forKey: "settings.autoSearch") as? Bool ?? true
    }
}

// MARK: - 人设（对应 bridge/persona.md，可在 App 内编辑）
//
// 人设 = 每次请求 system 消息的第一段（拼装在 MemoryStore.contextMessages）。
// 想改她的"出厂性格"：改下面 defaultPersona 的字符串。
// 想看/改用户当前实际生效的人设：设置 → 人设 页（PersonaEditor）。
// 持久化在 UserDefaults key "persona.md"（不是文件，名字只是沿用原项目习惯）。

@MainActor
final class PersonaStore: ObservableObject {
    // 改这里 = 改"恢复默认"按钮恢复到的人设。缩进会进字符串，顶格写每行。
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
//
// 记忆分两层（都是给模型看的上下文，见 contextMessages）：
// · entries（逐字窗口）：最近 N 条原文。N = settings.maxHistory，设置页可调。
//   超限时最老的一半被压进 summary（第 4 步在 append 里，见"滚动摘要"）。
// · summary（滚动摘要）：更早对话的粗压缩，拼进 system 消息，上限 60 行。
//
// 持久化：Documents/memory/default.json，每次 append/删除都原子写全量。
// contact 字段目前恒为 "default"——给"多联系人/多会话"预留的坑位：
//   想做多会话：把 fileURL 按 contact 命名（default.json → <contact>.json），
//   MemoryStore 按 contact 多实例化即可，UI 层要加会话列表。

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
        // 逐字窗口超限：把最老的一半压成摘要（滚动摘要）。
        // 注意：这里的"压缩"只是把老对话原文逐行拼进 summary，没有用模型总结——
        // 想要更聪明的摘要（让模型把老对话浓缩成几句话），在这里发一次后台
        // DeepSeek 请求替换 digest 内容即可，注意别阻塞 append。
        if record.entries.count > maxHistory {
            let old = record.entries.prefix(record.entries.count - maxHistory / 2)
            let digest = old.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
            // suffix(60)：摘要最多保留最近 60 行，防止无限膨胀吃 token
            record.summary = (record.summary + "\n" + digest)
                .split(separator: "\n").suffix(60).joined(separator: "\n")
            record.entries.removeFirst(record.entries.count - maxHistory / 2)
        }
        save()
    }

    /// 组装发给模型的上下文：system(人设+摘要) + 窗口
    /// 模型看到的完整结构 = [人设+摘要(system)] + [窗口内逐条对话]
    /// Pipeline.handle 会在拿到这个数组后，把最后一条 user 替换成带图片/文件块的版本
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
//
// 想加一种新背景（三处都要改）：
//   1. 这个 enum 加 case + name 中文名；
//   2. ChatView.chatBackgroundLayer 的 switch 加对应视图（真正生效的地方）；
//   3. ChatBackgroundView.preview 的 switch 加缩略图。
// 自定义照片有两个文件：chat_bg_original.jpg（相册原图，供反复重裁）和
// chat_bg.jpg（裁剪后的成品，实际显示）。imageRevision 用于让 CustomChatBackground
// 在文件内容变化时重新读盘（同路径重写 UIImage 有缓存，不加会显示旧图）。

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
