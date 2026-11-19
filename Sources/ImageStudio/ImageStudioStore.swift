import Foundation
import Combine

// MARK: - 生图工作室存储与生成编排（移植桌面端 store.js / engine.js / library.js 的宿主半）
//
// 数据都在 App 沙盒 Documents/image-studio/ 下（目录布局与桌面端插件一致，
// 理论上可以直接把桌面端的 library/ 目录拷进沙盒复用）：
//   config.json      配置（API Key 不在这里，进 Keychain）
//   presets.json     关键词库（首次运行写入默认值）
//   library/<类>/    四个参考库
//   outputs/<yyyy-MM>/ 生成的图片
//   history.jsonl    生成记录（一行一条 JSON，最近的在文件末尾）
//   .trash/          删除的素材挪到这里，不做硬删除

@MainActor
final class ImageStudioStore: ObservableObject {
    let rootDirectory: URL
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    /// 日程联动（对应桌面端 schedule-link 读 dsh-daily-schedule）
    private let schedule: ScheduleStore?
    /// 设置页「测试连接 / 试画」可以注入离线 session
    var client: ImageStudioClient

    @Published var config: StudioConfig { didSet { saveConfig() } }
    @Published var presets: StudioPresets { didSet { savePresets() } }
    @Published private(set) var library: [StudioCategory: [LibraryEntry]] = [:]
    /// 生成记录（追加序，最近在末尾）；UI 展示用 recentRecords
    @Published private(set) var history: [ImageRecord] = []
    /// 本轮聊天里刚生成的图（环形缓冲，ChatView / Pipeline 用 recordsSince 取）
    @Published private(set) var generationEpoch = 0
    private var generatedLog: [(epoch: Int, record: ImageRecord)] = []
    /// 上次工具出图时间（主动发图冷却用；不落盘）
    private(set) var lastShotAt: Date?

    /// API Key 属于敏感凭据：存 Keychain，Keychain 写失败退回 UserDefaults
    var apiKey: String {
        didSet {
            if (try? keychain.set(apiKey, account: Self.apiKeyAccount)) != nil {
                defaults.removeObject(forKey: Self.apiKeyDefaultsKey)
            } else {
                defaults.set(apiKey, forKey: Self.apiKeyDefaultsKey)
            }
        }
    }

    static let apiKeyAccount = "studio.apiKey"
    private static let apiKeyDefaultsKey = "studio.apiKey"
    /// 生成记录上限（对应桌面端 compactHistory maxEntries）
    private static let historyLimit = 2000
    /// 一次聊天里最多记这么多条生成，防止缓冲无限涨
    private static let generatedLogLimit = 40

    private static let imageExtensions = ["png", "jpg", "jpeg", "webp", "gif"]

    // MARK: - 初始化

    init(directory: URL,
         schedule: ScheduleStore? = nil,
         defaults: UserDefaults = .standard,
         keychain: KeychainStore = KeychainStore(),
         client: ImageStudioClient = ImageStudioClient()) {
        self.rootDirectory = directory
        self.schedule = schedule
        self.defaults = defaults
        self.keychain = keychain
        self.client = client
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Keychain 优先，其次迁移 UserDefaults 旧值
        if let fromKeychain = keychain.string(account: Self.apiKeyAccount) {
            apiKey = fromKeychain
        } else if let legacy = defaults.string(forKey: Self.apiKeyDefaultsKey), !legacy.isEmpty {
            apiKey = legacy
            if (try? keychain.set(legacy, account: Self.apiKeyAccount)) != nil {
                defaults.removeObject(forKey: Self.apiKeyDefaultsKey)
            }
        } else {
            apiKey = ""
        }

        config = Self.loadConfig(at: directory.appendingPathComponent("config.json"))
        presets = Self.loadPresets(at: directory.appendingPathComponent("presets.json"))
        history = Self.loadHistory(at: directory.appendingPathComponent("history.jsonl"))
        rescanLibrary()
    }

    // MARK: - 路径

    var outputsRoot: URL { rootDirectory.appendingPathComponent("outputs", isDirectory: true) }
    var trashRoot: URL { rootDirectory.appendingPathComponent(".trash", isDirectory: true) }
    func categoryDir(_ category: StudioCategory) -> URL {
        rootDirectory.appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)
    }
    /// 相对 outputs/ 的路径 → 绝对 URL
    func outputURL(_ relative: String) -> URL {
        outputsRoot.appendingPathComponent(relative)
    }
    /// 记录的第一张结果图绝对 URL
    func primaryImageURL(of record: ImageRecord) -> URL? {
        guard let rel = record.files.first else { return nil }
        let url = outputURL(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 配置持久化

    private static func loadConfig(at url: URL) -> StudioConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StudioConfig.self, from: data) else {
            return StudioConfig()
        }
        return decoded
    }

    private func saveConfig() {
        let url = rootDirectory.appendingPathComponent("config.json")
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 关键词持久化

    private static func loadPresets(at url: URL) -> StudioPresets {
        // 不存在时写入默认值；坏文件不覆盖，退回默认值继续工作（对应 presets.js loadPresets）
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(StudioPresets.self, from: data) {
            return StudioPresets.normalize(decoded)
        }
        let defaults = StudioDefaultPresets.presets
        if let data = try? JSONEncoder().encode(defaults) {
            try? data.write(to: url, options: .atomic)
        }
        return defaults
    }

    private func savePresets() {
        let url = rootDirectory.appendingPathComponent("presets.json")
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func resetPresetGroup(_ group: StudioPresetGroup) {
        presets.setItems(StudioDefaultPresets.presets.items(for: group), for: group)
    }

    // MARK: - 生成记录持久化（history.jsonl，一行一条）

    private static func loadHistory(at url: URL) -> [ImageRecord] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [ImageRecord] = []
        for line in raw.split(separator: "\n") {
            if let data = line.data(using: .utf8),
               let record = try? decoder.decode(ImageRecord.self, from: data) {
                records.append(record)
            }
        }
        // 超限裁掉最老的一半并重写文件（对应桌面端 compactHistory）
        if records.count > historyLimit {
            records = Array(records.suffix(historyLimit / 2))
            writeHistoryLines(records, to: url)
        }
        return records
    }

    private static func writeHistoryLines(_ records: [ImageRecord], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var text = ""
        for record in records {
            if let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) {
                text += line + "\n"
            }
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendHistory(_ record: ImageRecord) {
        history.append(record)
        let url = rootDirectory.appendingPathComponent("history.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: Data((line + "\n").utf8))
            } else {
                try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 找一条记录（img- 编号 → 记录），供 extra_images 解析
    func findHistory(_ id: String) -> ImageRecord? {
        history.last { $0.id == id }
    }

    /// UI 展示用：最新在前
    var recentRecords: [ImageRecord] {
        history.reversed()
    }

    /// 删除一条记录：图片挪进 .trash/outputs，记录标记 deleted（对应 engine.js deleteHistory）
    func deleteRecord(_ id: String) {
        guard let index = history.lastIndex(where: { $0.id == id }) else { return }
        let record = history[index]
        let dstDir = trashRoot.appendingPathComponent("outputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        for rel in record.files {
            let src = outputURL(rel)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.moveItem(at: src, to: dstDir.appendingPathComponent(src.lastPathComponent))
            }
        }
        var deleted = record
        deleted.status = "deleted"
        deleted.files = []
        history[index] = deleted
        appendHistory(deleted)
    }

    // MARK: - 参考库

    /// 扫描四个库目录（对应 library.js scanAll）：
    ///   <库目录>/<条目名>/entry.json + 参考图 ← 标准条目
    ///   <库目录>/<图片>.png                   ← 散图也算一条（名字 = 文件名）
    func rescanLibrary() {
        var result: [StudioCategory: [LibraryEntry]] = [:]
        for category in StudioCategory.allCases {
            result[category] = Self.scanCategory(category, dir: categoryDir(category))
        }
        library = result
    }

    nonisolated private static func scanCategory(_ category: StudioCategory, dir: URL) -> [LibraryEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var entries: [LibraryEntry] = []
        for item in contents where !item.lastPathComponent.hasPrefix(".") {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                entries.append(scanFolderEntry(category: category, id: item.lastPathComponent, dir: item))
            } else if imageExtensions.contains(item.pathExtension.lowercased()) {
                var entry = LibraryEntry(id: item.deletingPathExtension().lastPathComponent,
                                         category: category, isFolder: false,
                                         name: item.deletingPathExtension().lastPathComponent)
                entry.images = [item.lastPathComponent]
                entries.append(entry)
            }
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return entries
    }

    nonisolated private static func scanFolderEntry(category: StudioCategory, id: String, dir: URL) -> LibraryEntry {
        var meta = LibraryEntryMeta()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("entry.json")),
           let decoded = try? JSONDecoder().decode(LibraryEntryMeta.self, from: data) {
            meta = decoded
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var entry = LibraryEntry(
            id: id,
            category: category,
            isFolder: true,
            name: (meta.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? id : meta.name!.trimmingCharacters(in: .whitespaces),
            aliases: meta.aliases ?? [],
            tags: meta.tags ?? [],
            descriptionText: meta.description ?? "",
            persona: meta.persona ?? "",
            traits: meta.traits ?? "",
            defaultOutfit: meta.defaultOutfit ?? "",
            situationOutfits: meta.situationOutfits ?? [:],
            images: files)
        // 封面排第一（entry.json 指定的 cover，否则第一张）
        let cover = meta.cover ?? files.first
        if let cover, files.contains(cover) {
            entry.images = [cover] + files.filter { $0 != cover }
        }
        return entry
    }

    func entryImageURL(_ entry: LibraryEntry, file: String) -> URL {
        if entry.isFolder {
            return categoryDir(entry.category).appendingPathComponent(entry.id).appendingPathComponent(file)
        }
        return categoryDir(entry.category).appendingPathComponent(file)
    }

    var libraryCounts: [StudioCategory: Int] {
        var out: [StudioCategory: Int] = [:]
        for (category, entries) in library { out[category] = entries.count }
        return out
    }

    /// 新建条目：建文件夹、写参考图、写 entry.json，然后重扫（对应设置页「手动新建 + 上传参考图」）
    func createEntry(category: StudioCategory,
                     name: String,
                     aliases: [String],
                     tags: [String],
                     description: String,
                     persona: String = "",
                     traits: String = "",
                     defaultOutfit: String = "",
                     images: [Data]) throws -> LibraryEntry {
        let cleanName = studioSafeName(name)
        guard !cleanName.isEmpty else { throw StudioError(message: "条目名字不能为空") }
        let dir = categoryDir(category).appendingPathComponent(cleanName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cover = ""
        for (index, data) in images.enumerated() {
            let ext = studioSniffImage(data).isEmpty ? ".png" : studioSniffImage(data)
            let file = "\(String(format: "%02d", index + 1))\(ext)"
            try data.write(to: dir.appendingPathComponent(file), options: .atomic)
            if index == 0 { cover = file }
        }
        let now = Date()
        let meta = LibraryEntryMeta(name: cleanName, aliases: aliases, tags: tags,
                                    description: description, persona: persona,
                                    traits: traits, defaultOutfit: defaultOutfit,
                                    situationOutfits: nil, cover: cover,
                                    createdAt: now, updatedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? data.write(to: dir.appendingPathComponent("entry.json"), options: .atomic)
        }
        rescanLibrary()
        if let entry = library[category]?.first(where: { $0.id == cleanName }) {
            return entry
        }
        throw StudioError(message: "条目已创建，但扫描结果里没找到")
    }

    /// 修改条目元信息（entry.json），支持改描述/人设/默认服饰等
    func updateEntry(_ entryId: String, category: StudioCategory,
                     mutate: (inout LibraryEntryMeta) -> Void) throws {
        let dir = categoryDir(category).appendingPathComponent(entryId)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw StudioError(message: "找不到条目 \(entryId)")
        }
        var meta = LibraryEntryMeta()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("entry.json")),
           let decoded = try? JSONDecoder().decode(LibraryEntryMeta.self, from: data) {
            meta = decoded
        }
        mutate(&meta)
        meta.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? data.write(to: dir.appendingPathComponent("entry.json"), options: .atomic)
        }
        rescanLibrary()
    }

    /// 删除条目：挪进 .trash，不做硬删除（对应 library.js 的删除策略）
    func deleteEntry(_ entry: LibraryEntry) {
        let src: URL = entry.isFolder
            ? categoryDir(entry.category).appendingPathComponent(entry.id)
            : categoryDir(entry.category).appendingPathComponent(entry.images.first ?? "")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dstDir = trashRoot.appendingPathComponent(entry.category.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let unique = "\(entry.id)-\(Int(Date().timeIntervalSince1970))"
        try? FileManager.default.moveItem(at: src, to: dstDir.appendingPathComponent(unique))
        rescanLibrary()
    }

    // MARK: - 日程联动（对应 schedule-link.js）

    /// 日程此刻那一段 + 她的穿搭；读不到返回 nil，照旧走默认服饰规则
    func scheduleContext(now: Date = Date()) -> StudioScheduleContext? {
        guard let schedule, config.compose.followSchedule else { return nil }
        let dayKey = ScheduleStore.dateKey(for: now)
        guard let day = schedule.loadDay(dateKey: dayKey), !day.items.isEmpty else { return nil }
        let cal = Calendar.current
        let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        guard let item = day.items.first(where: { minute >= $0.startMinute && minute < $0.endMinute }) else {
            return nil
        }
        return StudioScheduleContext(characterName: schedule.characterName,
                                     start: item.start, end: item.end, activity: item.activity,
                                     outfit: item.outfit ?? "", outfitNote: item.outfitNote ?? "")
    }

    // MARK: - 生成（对应 engine.js runGeneration）

    static func newId(_ prefix: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = f.string(from: Date())
        let rand = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(prefix)\(stamp)-\(rand)"
    }

    /// 完整生成流程：组合参考 → 记「进行中」→ 调接口 → 存 outputs/ → 记「完成 / 失败」。
    /// 供 image_generate 工具与设置页「试画一张」共用。
    @discardableResult
    func generate(_ args: StudioGenerateArgs, source: String) async throws -> ImageRecord {
        guard config.enabled else {
            throw StudioError(message: "生图功能已在设置里关闭，本次没有出图。")
        }
        if source == "tool", !args.userRequested, config.policy.cooldownMin > 0, let last = lastShotAt {
            let gapMin = Date().timeIntervalSince(last) / 60
            if gapMin < Double(config.policy.cooldownMin) {
                throw StudioError(message: String(
                    format: "主动发图冷却中：距离上一张才 %.1f 分钟（设定至少 %d 分钟）。这次先不发；如果用户明确要图，带上 user_requested: true 再调用。",
                    gapMin, config.policy.cooldownMin))
            }
        }
        let prompt = args.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw StudioError(message: "prompt 不能为空：写一下这张图要画什么")
        }

        let scheduleCtx = scheduleContext()
        let extraCount = args.extraImages.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.count
        var plan = ImageStudioComposer.compose(args, config: config, library: library, presets: presets,
                                               schedule: scheduleCtx, extraCount: extraCount)

        // extra_images：历史 id → 本地文件，插到参考图最前面
        var extraRefs: [StudioRef] = []
        for raw in args.extraImages {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if let h = findHistory(s), let rel = h.files.first,
               FileManager.default.fileExists(atPath: outputURL(rel).path) {
                extraRefs.append(StudioRef(kind: "extra", label: "上一张生成图（\(s)）",
                                           category: nil, entryId: nil, name: nil, file: nil,
                                           url: outputURL(rel)))
            } else {
                plan.unresolved.append("参考图「\(s)」")
            }
        }
        // compose 只填了条目信息，文件路径在这里按库目录补上（发给 API 的参考图）
        let entryRefs = plan.refs.map { ref -> StudioRef in
            var r = ref
            if r.url == nil, let category = r.category, let entryId = r.entryId, let file = r.file,
               let entry = library[category]?.first(where: { $0.id == entryId }) {
                let url = entryImageURL(entry, file: file)
                if FileManager.default.fileExists(atPath: url.path) { r.url = url }
            }
            return r
        }
        plan.refs = extraRefs + entryRefs.filter { $0.url != nil }

        let id = Self.newId("img-")
        let started = Date()
        var record = ImageRecord(
            id: id,
            at: started,
            source: source,
            status: "running",
            prompt: prompt,
            caption: String(args.caption.prefix(300)),
            finalPrompt: plan.finalPrompt,
            aspect: plan.aspect,
            refs: Self.refSummaries(plan.refs),
            keywords: plan.keywords,
            notes: plan.notes,
            unresolved: plan.unresolved,
            model: config.api.model)
        appendHistory(record)

        do {
            let refURLs = plan.refs.compactMap(\.url)
            // API Key 单独存（Keychain），调接口前合回配置
            var requestConfig = config
            requestConfig.api.apiKey = apiKey
            let outcome = try await client.generate(config: requestConfig, prompt: plan.finalPrompt,
                                                    refURLs: refURLs, aspect: plan.aspect)
            let files = try saveOutputs(id: id, images: outcome.images)
            record.status = "done"
            record.files = files
            record.model = outcome.model
            record.size = outcome.size
            record.notes = plan.notes + outcome.notes
            record.ms = Int(Date().timeIntervalSince(started) * 1000)
            appendHistory(record)
            registerJustGenerated(record)
            lastShotAt = Date()
            return record
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            record.status = cancelled ? "cancelled" : "failed"
            record.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            record.ms = Int(Date().timeIntervalSince(started) * 1000)
            appendHistory(record)
            lastShotAt = Date()
            throw error
        }
    }

    /// 存结果图，返回相对 outputs/ 的路径（对应 engine.js saveOutputs）
    private func saveOutputs(id: String, images: [ImageStudioClient.GeneratedImage]) throws -> [String] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        let month = f.string(from: Date())
        let dir = outputsRoot.appendingPathComponent(month, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try images.enumerated().map { index, image in
            let file = "\(id)\(image.ext)"
            let url = dir.appendingPathComponent(file)
            try image.data.write(to: url, options: .atomic)
            return "\(month)/\(file)"
        }
    }

    /// 参考图摘要（连续同条目合并计数，对应 engine.js refSummary）
    private static func refSummaries(_ refs: [StudioRef]) -> [ImageRefSummary] {
        var out: [ImageRefSummary] = []
        for ref in refs {
            if ref.kind == "extra" {
                out.append(ImageRefSummary(kind: "extra", category: nil, id: nil, name: ref.label, count: 1))
                continue
            }
            if let last = out.last, last.kind == "entry", last.category == ref.category?.rawValue,
               last.id == ref.entryId {
                out[out.count - 1].count = (last.count ?? 1) + 1
            } else {
                out.append(ImageRefSummary(kind: "entry", category: ref.category?.rawValue,
                                           id: ref.entryId, name: ref.name, count: 1))
            }
        }
        return out
    }

    // MARK: - 给聊天那边的钩子

    /// ChatView / Pipeline 用：某一轮 handle 之前记下 epoch，之后 recordsSince(epoch) 拿新图
    func recordsSince(_ epoch: Int) -> [ImageRecord] {
        generatedLog.filter { $0.epoch > epoch }.map(\.record)
    }

    private func registerJustGenerated(_ record: ImageRecord) {
        generationEpoch += 1
        generatedLog.append((generationEpoch, record))
        if generatedLog.count > Self.generatedLogLimit {
            generatedLog.removeFirst(generatedLog.count - Self.generatedLogLimit)
        }
    }

    // MARK: - 给模型的注入文本 / 查询

    func guideText() -> String {
        ImageStudioGuide.guideText(config: config, library: library, presets: presets)
    }

    func libraryQueryText(category: String?, query: String?, id: String?) -> String {
        ImageStudioGuide.libraryQueryText(category: category, query: query, id: id, library: library)
    }
}
