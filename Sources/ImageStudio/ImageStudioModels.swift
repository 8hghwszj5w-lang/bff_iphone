import Foundation

// MARK: - 生图工作室数据模型（移植桌面端插件 dsh-image-studio）
//
// 对应关系（桌面 lib/*.js → 本文件）：
//   store.js   DEFAULT_CONFIG / POLICY_MODES / ASPECTS → StudioConfig 及默认值
//   presets.js DEFAULT_PRESETS / findPreset            → DEFAULT_PRESETS / StudioPreset.lookup
//   library.js entry.json 字段与目录约定               → LibraryEntry / LibraryEntryMeta
//   store.js   history.jsonl 记录形状                  → ImageRecord
//
// 数据都落在 App 沙盒 Documents/image-studio/ 下，目录布局与桌面端一致：
//   config.json / presets.json / history.jsonl
//   library/{characters,outfits,scenes,props}/<条目名>/entry.json + 参考图
//   outputs/<yyyy-MM>/<img-…>.png
//   .trash/   删除的素材挪到这里，不做硬删除
// 这样理论上可以直接把桌面端的素材库目录拷进沙盒复用。

// MARK: 配置

/// 发图时机三档（对应桌面 policy.mode），文案见 ImageStudioCompose.guideText
enum StudioPolicyMode: String, Codable, CaseIterable, Identifiable {
    case manual, balanced, proactive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: return "手动（只要图才画）"
        case .balanced: return "适中（好时刻才配图）"
        case .proactive: return "主动（闲聊多配图）"
        }
    }
}

struct StudioAPIConfig: Codable, Equatable {
    /// OpenAI 兼容接口根地址（…/v1）。65535 异步任务是桌面端专属，iOS 只走通用 images 接口。
    var baseURL = ""
    /// 生图模型名（如 qwen-image-2.1-pro / gpt-image-2）
    var model = ""
    /// 默认画幅比例（1:1 / 3:4 / 4:3 / 2:3 / 3:2 / 9:16 / 16:9）
    var defaultAspect = "3:4"
    /// 单次生成超时（秒）。生图普遍要几十秒，默认给足。
    var timeoutSec = 300
    var quality = ""
    /// API Key 不落盘（config.json 里没有这个字段）：真正存储在 Keychain，
    /// 由 ImageStudioStore 在调接口前把它合进来。
    var apiKey: String = ""

    enum CodingKeys: String, CodingKey {
        case baseURL, model, defaultAspect, timeoutSec, quality
    }

    static let aspects = ["1:1", "3:4", "4:3", "2:3", "3:2", "9:16", "16:9"]
}

struct StudioPolicy: Codable, Equatable {
    var mode: StudioPolicyMode = .balanced
    /// 两次主动发图的最小间隔（分钟）；0 = 不限
    var cooldownMin = 3
    /// 用户补充的发图规则（写进系统提示）
    var rules = ""
}

struct StudioComposeConfig: Codable, Equatable {
    /// 参考图总上限；人物/其他条目各自的张数配额
    var maxRefs = 8
    var refsPerCharacter = 2
    var refsPerOther = 1
    /// 自动认出画面描述里提到的库条目名字
    var autoMatch = true
    /// 没指定服饰时按「情境/场景默认 → 人物默认」自动搭配
    var useDefaultOutfit = true
    /// 沿用日程里她此刻的穿着（对应桌面端 schedule-link）
    var followSchedule = true
    /// 全局画风前缀
    var stylePrompt = ""
    /// 目录写进系统提示（库很大时可关掉，让模型用 image_library 查）
    var catalogInPrompt = true
    /// true：参考图只管长相与设计，姿势表情构图全按文字来（推荐）
    var identityOnly = true
    /// 日程里的「她」对应人物库哪条（名字或 id）；留空按名字匹配、库里只有一人时自动认
    var imageCharacter = ""
}

struct StudioConfig: Codable, Equatable {
    var enabled = true
    var api = StudioAPIConfig()
    var policy = StudioPolicy()
    var compose = StudioComposeConfig()
}

extension StudioConfig {
    /// 收敛任意输入成合法配置（对应桌面端 store.js normalizeConfig）：
    /// 数值越界夹住、枚举/画幅白名单、超长文本截断、地址去掉结尾斜杠。
    /// load / save 时都会过一遍，手改 config.json 写坏了也不会让设置页炸掉。
    func normalized() -> StudioConfig {
        var c = self
        c.api.baseURL = Self.cleanURL(c.api.baseURL)
        c.api.model = String(c.api.model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        c.api.quality = String(c.api.quality.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        if !StudioAPIConfig.aspects.contains(c.api.defaultAspect) {
            c.api.defaultAspect = StudioAPIConfig().defaultAspect
        }
        c.api.timeoutSec = min(1800, max(30, c.api.timeoutSec))
        c.policy.cooldownMin = min(240, max(0, c.policy.cooldownMin))
        c.policy.rules = String(c.policy.rules.prefix(4000))
        c.compose.maxRefs = min(16, max(1, c.compose.maxRefs))
        c.compose.refsPerCharacter = min(6, max(1, c.compose.refsPerCharacter))
        c.compose.refsPerOther = min(4, max(1, c.compose.refsPerOther))
        c.compose.stylePrompt = String(c.compose.stylePrompt.prefix(2000))
        c.compose.catalogInPrompt = c.compose.catalogInPrompt
        c.compose.identityOnly = c.compose.identityOnly
        c.compose.imageCharacter = String(
            c.compose.imageCharacter.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return c
    }

    /// 去掉首尾空白与结尾斜杠（对应桌面端 `str(url).trim().replace(/\/+$/, '')`）
    private static func cleanURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 512 { s = String(s.prefix(512)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: 关键词库（情境 / 神态 / 动作 / 镜头 / 光线）

/// 一条关键词。情境额外带默认搭配（场景/服饰/光线），展开时自动带上。
/// Identifiable 以名字为 id（关键词编辑 sheet 的 item 传参用）。
struct StudioPresetItem: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var aliases: [String] = []
    var prompt: String = ""
    /// 仅情境分组使用
    var scene: String? = nil
    var outfit: String? = nil
    var light: String? = nil

    private enum CodingKeys: String, CodingKey { case name, aliases, prompt, scene, outfit, light }
}

enum StudioPresetGroup: String, CaseIterable, Identifiable {
    case situation, expression, pose, shot, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .situation: return "情境"
        case .expression: return "神态"
        case .pose: return "动作"
        case .shot: return "镜头"
        case .light: return "光线"
        }
    }
}

/// 关键词库：分组名 → 条目列表。持久化在 presets.json。
struct StudioPresets: Codable, Equatable {
    var situation: [StudioPresetItem] = []
    var expression: [StudioPresetItem] = []
    var pose: [StudioPresetItem] = []
    var shot: [StudioPresetItem] = []
    var light: [StudioPresetItem] = []

    func items(for group: StudioPresetGroup) -> [StudioPresetItem] {
        switch group {
        case .situation: return situation
        case .expression: return expression
        case .pose: return pose
        case .shot: return shot
        case .light: return light
        }
    }

    mutating func setItems(_ items: [StudioPresetItem], for group: StudioPresetGroup) {
        switch group {
        case .situation: situation = items
        case .expression: expression = items
        case .pose: pose = items
        case .shot: shot = items
        case .light: light = items
        }
    }

    /// 按名字/别名找关键词；再退一步找唯一的包含匹配（对应 presets.js findPreset）。
    func lookup(_ group: StudioPresetGroup, _ ref: String) -> StudioPresetItem? {
        let key = Self.norm(ref)
        guard !key.isEmpty else { return nil }
        let items = items(for: group)
        let exact = items.first { Self.norm($0.name) == key }
            ?? items.first { $0.aliases.contains { Self.norm($0) == key } }
        if let exact { return exact }
        let loose = items.filter { item in
            ([item.name] + item.aliases).contains { n in
                let nn = Self.norm(n)
                return nn.count >= 2 && (key.contains(nn) || nn.contains(key))
            }
        }
        return loose.count == 1 ? loose[0] : nil
    }

    /// 名字归一：去空白、转小写（对应 presets.js norm）
    static func norm(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 收敛任意输入成合法关键词库（对应 presets.js normalizePresets：去空名、去重、每组上限 80）
    static func normalize(_ raw: StudioPresets) -> StudioPresets {
        var out = StudioPresets()
        for group in StudioPresetGroup.allCases {
            var seen = Set<String>()
            let items = raw.items(for: group).prefix(80).compactMap { item -> StudioPresetItem? in
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                var fixed = item
                fixed.name = String(name.prefix(40))
                fixed.aliases = fixed.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.prefix(12).map { String($0.prefix(40)) }
                fixed.prompt = String(fixed.prompt.prefix(600))
                if group == .situation {
                    fixed.scene = fixed.scene.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) }
                    fixed.outfit = fixed.outfit.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) }
                    fixed.light = fixed.light.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) }
                }
                guard !seen.contains(fixed.name) else { return nil }
                seen.insert(fixed.name)
                return fixed
            }
            out.setItems(Array(items), for: group)
        }
        return out
    }
}

/// 默认关键词库：逐条移植桌面端 presets.js 的 DEFAULT_PRESETS。
/// 情境里的场景/服饰名（卧室、居家针织服…）只是例子，库里没有时会只按文字描述画。
enum StudioDefaultPresets {
    static var presets: StudioPresets {
        var p = StudioPresets()
        p.situation = [
            .init(name: "在家休息", aliases: ["在家", "宅家", "休息", "放松", "居家"], prompt: "放松慵懒的居家氛围，周围有生活感的小物件", scene: "卧室", outfit: "居家针织服", light: "午后暖阳"),
            .init(name: "睡前", aliases: ["睡觉", "晚安", "熬夜"], prompt: "夜深了，准备睡觉，被子和枕头有些凌乱，安静温馨", scene: "卧室", outfit: "居家针织服", light: "夜晚台灯"),
            .init(name: "刚睡醒", aliases: ["起床", "早安", "赖床"], prompt: "刚睡醒，头发有点乱，还带着困意", scene: "卧室", outfit: "居家针织服", light: "清晨柔光"),
            .init(name: "客厅放松", aliases: ["看电视", "沙发", "窝沙发"], prompt: "窝在沙发上，悠闲自在", scene: "客厅", outfit: "居家针织服", light: "午后暖阳"),
            .init(name: "工作学习", aliases: ["上班", "工作", "学习", "干活", "写代码"], prompt: "在电脑或书桌前专注做事，桌上有电脑、笔记和一杯饮料", scene: "", outfit: "通勤休闲装", light: ""),
            .init(name: "外出", aliases: ["出门", "逛街", "约会", "散步"], prompt: "在户外，轻松愉快，背景是街道或公园", scene: "", outfit: "复古", light: "午后暖阳"),
            .init(name: "吃东西", aliases: ["吃饭", "下午茶", "零食", "吃饭饭"], prompt: "面前摆着诱人的食物，正准备开动或吃得很满足", scene: "", outfit: "", light: ""),
            .init(name: "下雨天", aliases: ["下雨", "雨天"], prompt: "窗外在下雨，玻璃上有雨痕，氛围安静", scene: "", outfit: "", light: "阴雨天"),
        ]
        p.expression = [
            .init(name: "开心", aliases: ["高兴", "愉快", "笑"], prompt: "眼睛弯成月牙，露出灿烂的笑容，神情明亮有活力"),
            .init(name: "微笑", aliases: ["温柔"], prompt: "嘴角轻轻上扬的温柔微笑，眼神柔和"),
            .init(name: "害羞", aliases: ["脸红", "不好意思"], prompt: "脸颊泛起红晕，眼神躲闪、微微低头，嘴角含着不好意思的笑"),
            .init(name: "得意", aliases: ["骄傲", "神气"], prompt: "扬起下巴，眯着眼露出得意的坏笑，一副「快夸我」的神气"),
            .init(name: "撒娇", aliases: ["卖萌"], prompt: "歪着头，眼睛亮晶晶地往上看，嘴角带着讨好的笑"),
            .init(name: "委屈", aliases: ["可怜"], prompt: "眉头微蹙，嘴巴瘪起，眼里含着要掉不掉的泪光"),
            .init(name: "生气", aliases: ["气鼓鼓", "不满"], prompt: "鼓起腮帮子，眉毛竖起，气呼呼地瞪着前方"),
            .init(name: "惊讶", aliases: ["吃惊", "震惊"], prompt: "眼睛睁大，嘴巴微张成 O 形，眉毛高高扬起"),
            .init(name: "困倦", aliases: ["困", "犯困", "没睡醒"], prompt: "半睁着惺忪的睡眼，打着哈欠或眼皮打架，神情迷糊"),
            .init(name: "认真", aliases: ["专注"], prompt: "神情专注，目光坚定，嘴唇轻抿"),
            .init(name: "平静", aliases: ["放空", "发呆"], prompt: "表情放松平和，目光自然或有点出神"),
            .init(name: "难过", aliases: ["伤心", "失落"], prompt: "眼神低垂黯淡，嘴角下撇，带着淡淡的忧伤"),
            .init(name: "无语", aliases: ["无奈", "白眼"], prompt: "半眯着眼，嘴角抽动，一脸「真拿你没办法」的无奈"),
            .init(name: "紧张", aliases: ["慌张"], prompt: "额角冒出细汗，眼神慌乱，嘴唇紧抿"),
        ]
        p.pose = [
            .init(name: "站着", aliases: ["站立"], prompt: "自然地站着，重心落在一条腿上，身体略微侧转"),
            .init(name: "坐着", aliases: ["坐"], prompt: "自然地坐着，身体放松，双手放在膝上或身侧"),
            .init(name: "抱膝坐", aliases: ["抱膝"], prompt: "坐在地上或床上，双臂环抱膝盖，下巴搁在膝头"),
            .init(name: "躺着", aliases: ["躺", "躺平"], prompt: "侧身或仰面躺着，身体舒展放松"),
            .init(name: "趴着", aliases: ["趴"], prompt: "趴在床上或桌上，双手托着下巴，小腿向上翘起"),
            .init(name: "伸懒腰", aliases: [], prompt: "双臂高举过头伸懒腰，身体舒展"),
            .init(name: "托腮", aliases: ["撑脸"], prompt: "一只手托着脸颊，手肘撑在桌面上"),
            .init(name: "挥手", aliases: ["打招呼"], prompt: "抬起一只手朝镜头挥手打招呼"),
            .init(name: "回头", aliases: ["回眸"], prompt: "背对镜头，转过头回眸看向镜头"),
            .init(name: "比耶", aliases: ["剪刀手"], prompt: "一只手在脸旁比出 V 字手势"),
            .init(name: "抱着东西", aliases: ["抱着"], prompt: "双手把东西抱在怀里"),
            .init(name: "看书", aliases: ["读书"], prompt: "低着头专注地看着手里的书"),
            .init(name: "喝饮料", aliases: ["喝咖啡", "捧着杯子"], prompt: "双手捧着杯子，小口喝着热饮"),
            .init(name: "奔跑", aliases: ["跑"], prompt: "向前小跑，头发和衣摆随动作飘起"),
        ]
        p.shot = [
            .init(name: "自拍", aliases: ["自拍照"], prompt: "手机自拍视角：人物一只手臂伸向镜头举着手机（手机在画面外），轻微俯拍，脸离镜头较近"),
            .init(name: "特写", aliases: ["大头"], prompt: "面部特写，聚焦表情和眼神"),
            .init(name: "近景", aliases: ["胸像"], prompt: "胸口以上的近景，人物占画面大部分"),
            .init(name: "半身", aliases: [], prompt: "腰部以上的半身构图"),
            .init(name: "全身", aliases: [], prompt: "全身入镜，能看清完整的姿势和服装"),
            .init(name: "远景", aliases: ["大场景"], prompt: "人物在画面中较小，突出环境与氛围"),
            .init(name: "俯视", aliases: ["俯拍"], prompt: "从高处向下俯拍的视角"),
            .init(name: "仰视", aliases: ["仰拍"], prompt: "从低处向上仰拍的视角"),
            .init(name: "第一人称", aliases: ["POV", "主观视角"], prompt: "第一人称视角，观看者就在人物面前，人物与镜头有互动"),
        ]
        p.light = [
            .init(name: "午后暖阳", aliases: ["午后", "阳光"], prompt: "午后温暖的阳光从窗户斜照进来，有柔和的光斑，整体暖色调"),
            .init(name: "清晨柔光", aliases: ["清晨", "早上"], prompt: "清晨柔和的自然光，色调清新明亮"),
            .init(name: "黄昏逆光", aliases: ["黄昏", "夕阳"], prompt: "黄昏的橙色逆光，人物轮廓镶着一圈金边"),
            .init(name: "夜晚台灯", aliases: ["夜晚", "晚上", "台灯"], prompt: "夜晚的室内，只有暖黄的台灯照明，周围偏暗，温馨安静"),
            .init(name: "霓虹夜景", aliases: ["霓虹", "夜景"], prompt: "夜晚街头的霓虹灯光，蓝紫与粉色的光影交错"),
            .init(name: "阴雨天", aliases: ["阴天", "雨天光"], prompt: "阴天或下雨，光线柔和偏冷，氛围安静"),
            .init(name: "月光", aliases: [], prompt: "夜晚冷蓝色的月光，静谧"),
        ]
        return StudioPresets.normalize(p)
    }
}

// MARK: 参考库条目

enum StudioCategory: String, CaseIterable, Identifiable {
    case characters, outfits, scenes, props
    var id: String { rawValue }
    var label: String {
        switch self {
        case .characters: return "人物"
        case .outfits: return "服饰"
        case .scenes: return "场景"
        case .props: return "道具"
        }
    }
}

/// 参考库条目（对应 library.js 的 folder/file entry）。
/// 目录约定：library/<类>/<条目名>/entry.json + 参考图；散图文件也算一条（id = 文件名去扩展名）。
struct LibraryEntry: Identifiable, Equatable {
    var id: String            // 目录名或文件名（去扩展名），防穿越：只取最后一seg
    var category: StudioCategory
    var isFolder: Bool
    var name: String
    var aliases: [String] = []
    var tags: [String] = []
    /// 外观/视觉描述——会写进生图提示词
    var descriptionText: String = ""
    /// 人设——只给对话模型看，不发给生图 API
    var persona: String = ""
    /// 神态/小动作特点（人物）——写进生图提示词
    var traits: String = ""
    /// 默认服饰（人物：没指定时穿；场景：在这个场景里默认穿）
    var defaultOutfit: String = ""
    /// 人物在各情境下穿什么：情境名 → 服饰名
    var situationOutfits: [String: String] = [:]
    /// 参考图文件名（封面排第一）
    var images: [String] = []

    var coverFile: String { images.first ?? "" }
}

/// entry.json 的落盘形状（与桌面端同构，字段可直接互换）
struct LibraryEntryMeta: Codable {
    var name: String?
    var aliases: [String]?
    var tags: [String]?
    var description: String?
    var persona: String?
    var traits: String?
    var defaultOutfit: String?
    var situationOutfits: [String: String]?
    var cover: String?
    var createdAt: Date?
    var updatedAt: Date?
}

// MARK: 生成记录（history.jsonl 的一行 / UI 的一张卡片）

struct ImageRefSummary: Codable, Equatable {
    var kind: String            // "entry" / "extra"
    var category: String?
    var id: String?
    var name: String?
    var count: Int?
}

/// 一次生成的完整记录。running → done / failed / cancelled。
struct ImageRecord: Codable, Identifiable, Equatable {
    var id: String              // img-…
    var at: Date
    var source: String          // tool / ui
    var status: String
    var prompt: String
    var caption: String
    var finalPrompt: String
    var aspect: String
    var refs: [ImageRefSummary]
    var keywords: [String: String]
    var notes: [String]
    var unresolved: [String]
    var model: String
    /// 接口返回的尺寸说明（部分接口给）
    var size: String = ""
    /// 相对 outputs/ 的文件路径（如 "2026-11/img-….png"）
    var files: [String] = []
    var ms: Int = 0
    var error: String = ""

    var isDone: Bool { status == "done" }
}

// MARK: 生成入参

/// image_generate 工具参数 & 设置页「试画一张」共用的入参形状
struct StudioGenerateArgs {
    var prompt = ""
    var situation = ""
    var expression = ""
    var pose = ""
    var shot = ""
    var light = ""
    var characters: [String] = []
    var outfits: [String] = []
    var scene = ""
    var props: [String] = []
    /// 要在其基础上修改的图：历史 id（img-…）
    var extraImages: [String] = []
    var aspect = ""
    var caption = ""
    var userRequested = false
}

// MARK: 其他

/// 可读错误（设置页 / 工具结果直接展示 message）
struct StudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 主动发图冷却中：这不是错误——对应桌面端 index.js 返回的 { ok: false, message }，
/// 工具层要把 message 当普通文本结果给模型（而不是 {"error": …}），模型才知道「这次先不发」。
struct StudioCooldownMessage: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 按文件头判断图片类型（对应 library.js sniffImage），返回扩展名（含点）；不是图片返回空串
func studioSniffImage(_ data: Data) -> String {
    guard data.count >= 12 else { return "" }
    let b = [UInt8](data.prefix(12))
    if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return ".png" }
    if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return ".jpg" }
    if data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WEBP".utf8) { return ".webp" }
    if data.prefix(3) == Data("GIF".utf8) { return ".gif" }
    return ""
}

func studioMime(of ext: String) -> String {
    switch ext.lowercased() {
    case ".png": return "image/png"
    case ".jpg", ".jpeg": return "image/jpeg"
    case ".webp": return "image/webp"
    case ".gif": return "image/gif"
    default: return "application/octet-stream"
    }
}

/// 文件夹/条目名清洗（对应 library.js safeName）：去路径分隔与首尾点空格，限 80 字
func studioSafeName(_ raw: String) -> String {
    var cleaned = raw
    for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\0"] {
        cleaned = cleaned.replacingOccurrences(of: ch, with: " ")
    }
    cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return String(cleaned.prefix(80))
}

// MARK: - 数据文件编解码（兼容桌面端写法）

/// entry.json / history.jsonl 的日期读写。
///
/// 桌面端 `new Date().toISOString()` 写的是 ISO 字符串（带毫秒），而 JSONDecoder 默认的
/// `.deferredToDate` 只吃数字时间戳——用默认解码器读桌面格式，entry.json 整条解不出来
/// （名字 / 描述 / 默认服饰全丢），history.jsonl 整行被丢掉。这里统一兜底：
/// 数字时间戳（秒/毫秒）、ISO 带毫秒、ISO 不带毫秒都认；写出去统一 ISO 带毫秒，与桌面端互通。
enum StudioJSON {
    private static let isoWithMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoWithMillis.string(from: date))
        }
        return encoder
    }

    /// 落盘用：字段排序 + 缩进，方便手工编辑与 diff
    static func prettyEncoder() -> JSONEncoder {
        let encoder = self.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                // 13 位按毫秒、10 位按秒（早期可能写过数字时间戳）
                return Date(timeIntervalSince1970: abs(number) > 1e11 ? number / 1000 : number)
            }
            let text = try container.decode(String.self)
            if let date = isoWithMillis.date(from: text) ?? isoPlain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期：\(text)")
        }
        return decoder
    }

    /// 以默认值为底、把文件里的对象叠上去（缺字段回默认，对应桌面端 store.js deepMerge）。
    /// 桌面端的接口地址字段名是 baseUrl，这里顺手映射成 iOS 的 baseURL。
    static func merge(base: Any, patch: Any) -> Any {
        guard let patchObject = patch as? [String: Any],
              let baseObject = base as? [String: Any] else { return patch }
        var out = baseObject
        for (key, value) in patchObject {
            let target = key == "baseUrl" ? "baseURL" : key
            if let existing = out[target] {
                out[target] = merge(base: existing, patch: value)
            } else {
                out[target] = value
            }
        }
        return out
    }
}
