import Foundation

// MARK: - 组合引擎（移植桌面端插件 dsh-image-studio 的 compose.js / prompt.js / schedule-link.js）
//
// 把「画面描述 + 关键词 + 选中的库条目」组合成一次生图请求：
//  1. 关键词：情境 / 神态 / 动作 / 镜头 / 光线填名字即可，展开成具体描写；没收录的词原样当描述用；
//  2. 情境带出默认搭配：场景、光线，以及服饰——人物在该情境的专属服饰 > 情境默认服饰；
//  3. 解析人物 / 服饰 / 场景 / 道具（id、名字、别名都认），可选自动认出描述里提到的库名字；
//  4. 服饰兜底顺序：显式指定 > 日程里她此刻的穿着 > 人物的情境穿搭 > 情境默认 > 场景默认 > 人物默认；
//  5. 按优先级挑参考图（上一张图 > 人物 > 服饰 > 场景 > 道具），总数不超过 maxRefs；
//  6. 给每张参考图编号并写明「只取什么」——参考图只管长相与设计，
//     姿势、表情、视角、构图都由文字决定（不然出图会照抄参考图的姿势）。
//
// 注：extra_images（在上一张图基础上改）由 Store 先解析成 StudioExtraInput（查历史 / 读本机绝对路径），
// 再交给 compose——编号、参考图预算和提示词里的「图N：上一张生成图…」行都在 compose 里统一排
//（对应桌面端 compose.js:161-165 / 186-192 / 225-232）。

/// 一张参考图（发给 API 的一张 + 提示词里的一行说明）
struct StudioRef: Equatable {
    var kind: String            // "entry" / "extra"
    var label: String
    var category: StudioCategory?
    var entryId: String?
    var name: String?
    var file: String?
    var url: URL?
}

/// extra_images 的一条：原始引用 + 解析结果（nil 表示解析不了，只进 unresolved，不占参考图预算）
struct StudioExtraInput {
    var raw: String
    var ref: StudioRef?
}

/// 一次组合的结果
struct StudioPlan {
    var characters: [LibraryEntry] = []
    var outfits: [LibraryEntry] = []
    var scene: LibraryEntry?
    var props: [LibraryEntry] = []
    var refs: [StudioRef] = []
    var finalPrompt = ""
    var aspect = ""
    var notes: [String] = []
    var unresolved: [String] = []
    var keywords: [String: String] = [:]
}

/// 日程联动上下文：由 Store 从 ScheduleStore 读好再传进来（compose 保持纯函数、可离线测试）。
/// 对应桌面端 schedule-link.js 的 currentScheduleItem + scheduleOutfitFor。
struct StudioScheduleContext {
    var characterName: String   // 日程里的她叫什么
    var start: String
    var end: String
    var activity: String
    var outfit: String          // 这一段的穿搭（服饰库名字，可能不在库里）
    var outfitNote: String      // 穿搭细节补充
    /// 这一段对应的生图场景名（对应 ScheduleItem.scene）：和这次画的场景不一致就不沿用穿搭
    var scene: String = ""
    /// 这一段对应的生图情境关键词（对应 ScheduleItem.situation）
    var situation: String = ""
}

enum ImageStudioComposer {

    // MARK: 画幅

    /// 全角冒号/×等写法归一成 "a:b" 或 "WxH"；认不出返回 fallback
    static func normalizeAspect(_ v: String, fallback: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "：", with: ":")
        s = s.replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "*", with: "x")
            .replacingOccurrences(of: "X", with: "x")
        if s.range(of: #"^\d{1,2}:\d{1,2}$"#, options: .regularExpression) != nil { return s }
        if s.range(of: #"^\d{3,4}x\d{3,4}$"#, options: .regularExpression) != nil { return s }
        return fallback
    }

    // MARK: 条目解析

    /// 条目在有序列表里的去重键
    fileprivate static func entryKey(_ e: LibraryEntry) -> String { "\(e.category.rawValue)/\(e.id)" }

    /// 按 id / 名字 / 别名精确找；再退一步找唯一的包含匹配（对应 library.js resolveRef）
    static func resolveRef(_ category: StudioCategory, _ ref: String,
                           library: [StudioCategory: [LibraryEntry]]) -> LibraryEntry? {
        let key = StudioPresets.norm(ref)
        guard !key.isEmpty else { return nil }
        let list = library[category] ?? []
        let exact = list.first { StudioPresets.norm($0.id) == key }
            ?? list.first { StudioPresets.norm($0.name) == key }
            ?? list.first { entry in entry.aliases.contains { StudioPresets.norm($0) == key } }
        if let exact { return exact }
        let loose = list.filter { entry in
            ([entry.name] + entry.aliases).contains { n in
                let nn = StudioPresets.norm(n)
                return !nn.isEmpty && (key.contains(nn) || nn.contains(key))
            }
        }
        return loose.count == 1 ? loose[0] : nil
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            ("\u{3040}"..."\u{30FF}").contains(scalar) || ("\u{3400}"..."\u{9FFF}").contains(scalar)
                || ("\u{F900}"..."\u{FAFF}").contains(scalar)
        }
    }

    /// 英文词边界查找：前后不能是字母/数字（对应 desktop 的 `(^|[^a-z0-9])name($|[^a-z0-9])`）
    private static func matchesWholeWord(_ word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let r = text.range(of: word, range: searchStart..<text.endIndex) {
            let beforeOK = r.lowerBound == text.startIndex || {
                let prev = text.index(before: r.lowerBound)
                let c = text[prev]
                return !(c.isLetter || c.isNumber)
            }()
            let afterOK = r.upperBound == text.endIndex || {
                let next = text.index(after: r.upperBound)
                let c = text[next]
                return !(c.isLetter || c.isNumber)
            }()
            if beforeOK && afterOK { return true }
            searchStart = r.upperBound
        }
        return false
    }

    /// 在一段文字里找出提到的条目（名字/别名）。英文名至少 3 个字母且按词边界匹配。
    static func mentionedIn(_ category: StudioCategory, _ text: String,
                            library: [StudioCategory: [LibraryEntry]]) -> [LibraryEntry] {
        let low = text.lowercased()
        var hits: [LibraryEntry] = []
        for entry in library[category] ?? [] {
            let names = ([entry.name] + entry.aliases).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let ok = names.contains { n in
                if containsCJK(n) { return text.contains(n) }
                guard n.count >= 3 else { return false }
                return matchesWholeWord(n.lowercased(), in: low)
            }
            if ok { hits.append(entry) }
        }
        return hits
    }

    // MARK: 主流程

    /// 把工具参数组合成一次生图请求（对应 compose.js compose）。
    /// extras：已解析的 extra_images（历史 id / 本机绝对路径 → 文件），按上传顺序排在最前、占参考图预算。
    static func compose(_ args: StudioGenerateArgs,
                        config: StudioConfig,
                        library: [StudioCategory: [LibraryEntry]],
                        presets: StudioPresets,
                        schedule: StudioScheduleContext? = nil,
                        extras: [StudioExtraInput] = []) -> StudioPlan {
        var plan = StudioPlan()
        var notes: [String] = []
        var unresolved: [String] = []
        var textOnly: [String] = []      // 库里没有、只能写成文字的搭配
        let prompt = args.prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // ---- 关键词 ----
        let situationRaw = args.situation.trimmingCharacters(in: .whitespacesAndNewlines)
        var situation: StudioPresetItem?
        var situationIsPreset = false
        if !situationRaw.isEmpty {
            if let p = presets.lookup(.situation, situationRaw) {
                situation = p
                situationIsPreset = true
            } else {
                situation = StudioPresetItem(name: situationRaw, prompt: situationRaw)
            }
        }
        var kw: [StudioPresetGroup: StudioPresetItem] = [:]
        for group in [StudioPresetGroup.expression, .pose, .shot, .light] {
            let raw: String
            switch group {
            case .expression: raw = args.expression
            case .pose: raw = args.pose
            case .shot: raw = args.shot
            case .light: raw = args.light
            default: raw = ""
            }
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            kw[group] = presets.lookup(group, v) ?? StudioPresetItem(name: v, prompt: v)
        }
        if kw[.light] == nil, let sit = situationIsPreset ? situation : nil,
           let light = sit.light, !light.isEmpty {
            kw[.light] = presets.lookup(.light, light) ?? StudioPresetItem(name: light, prompt: light)
        }

        // ---- 库条目 ----
        func pickMany(_ category: StudioCategory, _ refs: [String]) -> [LibraryEntry] {
            var out: [LibraryEntry] = []
            for r in refs {
                let name = r.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if let e = resolveRef(category, name, library: library) {
                    if !out.contains(e) { out.append(e) }
                } else {
                    unresolved.append("\(category.label)「\(name)」")
                }
            }
            return out
        }
        let characters = pickMany(.characters, args.characters)
        var outfits = pickMany(.outfits, args.outfits)
        let scenes = pickMany(.scenes, args.scene.isEmpty ? [] : [args.scene])
        plan.props = pickMany(.props, args.props)
        if scenes.count > 1 { notes.append("场景只能用一个，已用「\(scenes[0].name)」") }
        var scene = scenes.first
        if scene == nil, let sit = situationIsPreset ? situation : nil,
           let sceneName = sit.scene, !sceneName.isEmpty {
            if let e = resolveRef(.scenes, sceneName, library: library) {
                scene = e
                notes.append("情境「\(sit.name)」→ 场景「\(e.name)」")
            } else {
                textOnly.append("场景：\(sceneName)")
            }
        }

        // 自动认出画面描述里提到的条目
        var charactersFinal = characters
        if config.compose.autoMatch, !prompt.isEmpty {
            var auto: [LibraryEntry] = []
            for e in mentionedIn(.characters, prompt, library: library) where !charactersFinal.contains(e) {
                charactersFinal.append(e)
                auto.append(e)
            }
            for e in mentionedIn(.outfits, prompt, library: library) where !outfits.contains(e) {
                outfits.append(e)
                auto.append(e)
            }
            if scene == nil, let hit = mentionedIn(.scenes, prompt, library: library).first {
                scene = hit
                auto.append(hit)
            }
            for e in mentionedIn(.props, prompt, library: library) where !plan.props.contains(e) {
                plan.props.append(e)
                auto.append(e)
            }
            if !auto.isEmpty {
                notes.append("从画面描述里自动认出：" + auto.map { "\($0.category.label)「\($0.name)」" }.joined(separator: "、"))
            }
        }

        // 服饰兜底：日程此刻的穿着 > 人物的情境穿搭 > 情境默认 > 场景默认 > 人物默认
        var dressed = Set<String>()
        if outfits.isEmpty, config.compose.followSchedule, !charactersFinal.isEmpty, let sched = schedule {
            // 场景守卫（对应桌面端 schedule-link.js:90-93）：画的场景和日程此刻的场景不是同一个，
            // 说明画的不一定是「此刻」，就不沿用日程里的穿搭。
            var sceneMismatch = false
            if let drawnScene = scene, !sched.scene.isEmpty,
               let scheduledScene = resolveRef(.scenes, sched.scene, library: library),
               scheduledScene.id != drawnScene.id {
                sceneMismatch = true
            }
            let her = sceneMismatch ? nil : resolveHer(config: config, library: library, scheduleName: sched.characterName)
            for c in charactersFinal {
                guard let her, her.id == c.id else { continue }
                let outfitName = sched.outfit.trimmingCharacters(in: .whitespaces)
                let outfitNote = sched.outfitNote.trimmingCharacters(in: .whitespaces)
                guard !outfitName.isEmpty || !outfitNote.isEmpty else { continue }
                dressed.insert(c.id)
                if let o = outfitName.isEmpty ? nil : resolveRef(.outfits, outfitName, library: library) {
                    if !outfits.contains(o) { outfits.append(o) }
                    if !outfitNote.isEmpty { textOnly.append("\(c.name)的穿着细节：\(outfitNote)") }
                    notes.append("沿用\(c.name)此刻身上穿的「\(o.name)」" + (outfitNote.isEmpty ? "" : "（\(outfitNote)）"))
                } else {
                    let text = [outfitName, outfitNote].filter { !$0.isEmpty }.joined(separator: "，")
                    textOnly.append("\(c.name)穿着\(text)")
                    notes.append("沿用\(c.name)此刻身上穿的：\(text)（服饰库里没有，只按文字描述）")
                }
            }
        }
        if outfits.isEmpty, config.compose.useDefaultOutfit {
            for c in charactersFinal where !dressed.contains(c.id) {
                var candidates: [(String, String)] = []
                if let sit = situationIsPreset ? situation : nil {
                    if let o = c.situationOutfits[sit.name], !o.isEmpty {
                        candidates.append((o, "「\(c.name)」在情境「\(sit.name)」的穿搭"))
                    }
                    if let o = sit.outfit, !o.isEmpty {
                        candidates.append((o, "情境「\(sit.name)」的默认服饰"))
                    }
                }
                if let sc = scene, !sc.defaultOutfit.isEmpty {
                    candidates.append((sc.defaultOutfit, "场景「\(sc.name)」的默认服饰"))
                }
                if !c.defaultOutfit.isEmpty {
                    candidates.append((c.defaultOutfit, "「\(c.name)」的默认服饰"))
                }
                for (name, why) in candidates {
                    if let o = resolveRef(.outfits, name, library: library) {
                        if !outfits.contains(o) { outfits.append(o) }
                        notes.append("\(why)「\(o.name)」")
                        break
                    }
                    if !name.isEmpty {
                        textOnly.append("\(c.name)穿着\(name)")
                        notes.append("\(why)「\(name)」库里没有，只按文字描述")
                        break
                    }
                }
            }
        }

        // ---- 上一张图（extra_images）：只有解析成功（历史记录 / 本机绝对路径）的才占参考图预算 ----
        var extraRefs: [StudioRef] = []
        for input in extras {
            if let ref = input.ref {
                extraRefs.append(ref)
            } else {
                unresolved.append("参考图「\(input.raw)」")
            }
        }

        // ---- 挑参考图 ----
        var ordered = charactersFinal + outfits + (scene.map { [$0] } ?? []) + plan.props
        var seen = Set<String>()
        ordered = ordered.filter { seen.insert(entryKey($0)).inserted }

        func quota(_ e: LibraryEntry) -> Int {
            e.category == .characters ? max(1, config.compose.refsPerCharacter) : max(1, config.compose.refsPerOther)
        }
        let budget = max(0, config.compose.maxRefs - extraRefs.count)
        var chosen: [String: [String]] = [:]   // entryKey → 已选文件名
        var used = 0
        var round = 0
        while round < 6 && used < budget {
            for e in ordered {
                if used >= budget { break }
                let picked = chosen[entryKey(e)] ?? []
                if picked.count > round || picked.count >= quota(e) { continue }
                guard round < e.images.count else { continue }
                chosen[entryKey(e), default: []].append(e.images[round])
                used += 1
            }
            round += 1
        }
        let dropped = ordered.filter { !$0.images.isEmpty && (chosen[entryKey($0)] ?? []).isEmpty }
        if !dropped.isEmpty {
            notes.append("参考图超过上限 \(config.compose.maxRefs) 张，没放进去：\(dropped.map(\.name).joined(separator: "、"))（只按文字描述）")
        }

        // 顺序即上传顺序：上一张图在最前，其余按 人物 > 服饰 > 场景 > 道具
        var refs: [StudioRef] = extraRefs
        for e in ordered {
            for f in chosen[entryKey(e)] ?? [] {
                refs.append(StudioRef(kind: "entry", label: "\(e.category.label)「\(e.name)」",
                                      category: e.category, entryId: e.id, name: e.name, file: f, url: nil))
            }
        }

        // ---- 写提示词 ----
        let loose = config.compose.identityOnly
        let single = charactersFinal.count == 1 ? charactersFinal[0] : nil
        let hint: [StudioCategory: String] = loose
            ? [
                .characters: "只用来确定长相：脸型五官、发型发色、瞳色、体型比例和标志性特征。参考图里的姿势、表情、视角和背景都不要照搬。",
                .outfits: single.map { "只参考服装设计（款式、颜色、材质、细节），穿在「\($0.name)」身上，随动作自然起褶变形。" }
                    ?? "只参考服装设计（款式、颜色、材质、细节），随人物动作自然起褶变形。",
                .scenes: "只参考空间、陈设、配色与风格；镜头角度和取景按上面的描述重新安排。",
                .props: "只参考外形、材质与配色。",
            ]
            : [
                .characters: "外貌（脸、发型发色、体型、标志性特征）严格以参考图为准。",
                .outfits: single.map { "给「\($0.name)」穿上这套服饰，款式、材质与配色按参考图还原。" }
                    ?? "服饰款式、材质与配色按参考图还原。",
                .scenes: "画面发生在这个场景里，空间布局、陈设与光线氛围参考此图。",
                .props: "道具外形按参考图还原。",
            ]

        var parts: [String] = []
        let style = config.compose.stylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty { parts.append("【画风】\(style)") }
        parts.append("【画面】\(prompt)")
        if let sit = situation {
            let extra = (situationIsPreset && !sit.prompt.isEmpty) ? "：\(sit.prompt)" : ""
            parts.append("【情境】\(sit.name)\(extra)")
        }
        for group in [StudioPresetGroup.expression, .pose, .shot, .light] {
            if let k = kw[group] {
                let label = group == .light ? "光线氛围" : group.label
                parts.append("【\(label)】\(k.prompt.isEmpty ? k.name : k.prompt)")
            }
        }
        let traits = charactersFinal.filter { !$0.traits.trimmingCharacters(in: .whitespaces).isEmpty }
        if !traits.isEmpty {
            parts.append("【人物神态特点】\n" + traits.map { "\($0.name)：\(oneLine($0.traits))" }.joined(separator: "\n"))
        }
        if !textOnly.isEmpty { parts.append("【搭配】\(textOnly.joined(separator: "；"))") }

        var lines: [String] = []
        var noImage: [String] = []
        var n = 0
        func rangeLabel(_ count: Int) -> String {
            let a = n + 1
            n += count
            return count == 1 ? "图\(a)" : "图\(a)–\(n)"
        }
        // 上一张图占最前面的编号，并单独写一行「在它的基础上改，没提到的保持不变」（对应 compose.js:225-232）
        if !extraRefs.isEmpty {
            lines.append("\(rangeLabel(extraRefs.count))：\(extraRefs.map(\.label).joined(separator: "、"))——在它的基础上按要求修改，没提到要改的部分保持不变。")
        }
        for e in ordered {
            let cnt = chosen[entryKey(e)]?.count ?? 0
            let desc = oneLine(e.descriptionText)
            if cnt == 0 {
                noImage.append("\(e.category.label)「\(e.name)」：\(desc.isEmpty ? "（无描述）" : desc)")
                continue
            }
            var line = "\(rangeLabel(cnt))：\(e.category.label)「\(e.name)」——\(hint[e.category] ?? "")"
            if !desc.isEmpty { line += "\n  外观：\(desc)" }
            lines.append(line)
        }
        if !lines.isEmpty { parts.append("【参考图说明（按上传顺序编号）】\n\(lines.joined(separator: "\n"))") }
        if !noImage.isEmpty { parts.append("【没有参考图、只按文字描述的元素】\n\(noImage.joined(separator: "\n"))") }
        if !lines.isEmpty {
            parts.append(loose
                ? "要求：画一张全新的画面，不要把参考图拼贴、并排或作为画中画放进去。参考图只负责「长得像」：脸、发型发色、体型、标志性特征、服装款式与配色必须一致。构图、视角、景别、姿势、动作、手势、朝向、表情、光线方向和背景陈设，一律按上面的【画面】【情境】【神态】【动作】【镜头】【光线氛围】重新安排，不要沿用任何一张参考图里的站姿、坐姿、表情或取景；两者冲突时以文字为准。"
                : "要求：把以上参考融合成一张完整、自然的新画面，不要把参考图拼贴、并排或作为画中画放进画面；人物外貌必须与参考图一致。")
        }

        var keywords: [String: String] = [:]
        if let sit = situation { keywords["situation"] = sit.name }
        for group in [StudioPresetGroup.expression, .pose, .shot, .light] {
            if let k = kw[group] { keywords[group.rawValue] = k.name }
        }

        plan.characters = charactersFinal
        plan.outfits = outfits
        plan.scene = scene
        plan.refs = refs
        plan.finalPrompt = parts.joined(separator: "\n\n")
        plan.aspect = normalizeAspect(args.aspect, fallback: config.api.defaultAspect)
        plan.notes = notes
        plan.unresolved = unresolved
        plan.keywords = keywords
        return plan
    }

    /// 日程里的她对应人物库哪条（对应 schedule-link.js scheduleCharacter）：
    /// 配置指定 > 日程角色名/别名 > 库里只有一个人
    static func resolveHer(config: StudioConfig,
                           library: [StudioCategory: [LibraryEntry]],
                           scheduleName: String) -> LibraryEntry? {
        for name in [config.compose.imageCharacter, scheduleName] where !name.isEmpty {
            if let e = resolveRef(.characters, name, library: library) { return e }
        }
        let all = library[.characters] ?? []
        return all.count == 1 ? all[0] : nil
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 系统提示注入（对应 prompt.js guideText / catalogText）

enum ImageStudioGuide {

    private static let modeText: [StudioPolicyMode: String] = [
        .manual: "只在用户明确要图时调用（例如「画一张」「发张图」「让我看看」「生成图片」）。其余时候不要主动发图。",
        .balanced: "用户要图时调用。此外，在画面感强、配一张图明显加分的时刻（进入新场景、换装、关键动作、重要瞬间）可以主动发一张；日常问答、写代码、处理文件时不要发，也不要连续几轮都发。",
        .proactive: "在角色扮演和闲聊里积极配图：场景、动作、服装或情绪有明显变化时就主动发一张，让对话更有画面感；同一画面不要重复发；写代码等工作场景不发。",
    ]

    static func oneLine(_ s: String, max: Int) -> String {
        let t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    /// 参考库目录：每个库一行，只列名字、别名和一句描述，控制在几 KB 内
    static func catalogText(_ library: [StudioCategory: [LibraryEntry]], maxChars: Int = 3600) -> String {
        var budget = maxChars
        var sections: [String] = []
        for category in StudioCategory.allCases {
            let list = library[category] ?? []
            let head = "\(category.label)（\(category.rawValue)）"
            if list.isEmpty {
                sections.append("\(head)：暂无")
                continue
            }
            var items: [String] = []
            var shown = 0
            for e in list {
                let idPart = e.id != e.name ? " [id: \(e.id)]" : ""
                let alias = e.aliases.isEmpty ? "" : "（又名 \(e.aliases.prefix(3).joined(separator: "/"))）"
                let desc = e.descriptionText.isEmpty ? "" : " — \(oneLine(e.descriptionText, max: 40))"
                let imgs = e.images.isEmpty ? " (无图)" : ""
                let item = "\(e.name)\(idPart)\(alias)\(desc)\(imgs)"
                if budget - item.count < 0 { break }
                budget -= item.count + 2
                items.append(item)
                shown += 1
            }
            let more = list.count > shown ? "；…还有 \(list.count - shown) 项，用 image_library 查" : ""
            sections.append("\(head)：\(items.joined(separator: "；"))\(more)")
        }
        return sections.joined(separator: "\n")
    }

    static func keywordText(_ presets: StudioPresets) -> String {
        var lines: [String] = []
        for group in StudioPresetGroup.allCases {
            let items = presets.items(for: group)
            guard !items.isEmpty else { continue }
            lines.append("\(group.label)（\(group.rawValue)）：\(items.map(\.name).joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    /// 注入给对话模型的「生图说明 + 参考库目录」（对应 prompt.js guideText）
    static func guideText(config: StudioConfig,
                          library: [StudioCategory: [LibraryEntry]],
                          presets: StudioPresets) -> String {
        guard config.enabled else { return "" }
        var lines: [String] = []
        lines.append("# 生图（image_generate）")
        lines.append("你可以调用 image_generate 生成图片，图片会直接显示在对话里给用户看。")
        lines.append("何时发图：\(modeText[config.policy.mode] ?? modeText[.balanced]!)")
        let rules = config.policy.rules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rules.isEmpty { lines.append("用户补充的发图规则：\(rules)") }
        if config.policy.cooldownMin > 0 {
            lines.append("没被要求时，两次主动发图至少间隔 \(config.policy.cooldownMin) 分钟。用户本轮明确要图时把 user_requested 设为 true（不受间隔限制）。")
        } else {
            lines.append("用户本轮明确要图时把 user_requested 设为 true。")
        }
        lines.append("怎么调用：先想清楚角色此刻的状态——在哪、在做什么、心情如何——再选关键词：situation（情境，会自动带上对应的场景、服饰和光线）、expression（神态）、pose（动作）、shot（镜头）、light（光线），填下面列出的名字即可，会展开成具体描写；没有合适的就直接写一句具体描述。prompt 写这一张画面本身：发生了什么、和周围的互动、构图与情绪重点。")
        lines.append("参考图只负责长相与服装设计；姿势、表情、视角、景别、光线都由关键词和 prompt 决定，不写就容易照搬参考图，所以每张图都要按当下的情境换着来，别总是同一个站姿和表情。")
        lines.append("用 characters / outfits / scene / props 指定参考库条目（填 id 或名字）；服饰不指定时会沿用她此刻日程里穿的（那段日程写了穿搭的话），否则按情境和场景自动搭配；想让她穿别的就在 outfits 里写明。想在上一张图的基础上修改时，把它的图片编号（img- 开头）放进 extra_images。一次调用出一张图，出图需要几十秒。")
        let kw = keywordText(presets)
        if !kw.isEmpty {
            lines.append("可用关键词：")
            lines.append(kw)
        }
        if config.compose.catalogInPrompt {
            lines.append("参考库：")
            lines.append(catalogText(library))
        } else {
            lines.append("参考库里有哪些人物、服饰、场景、道具，用 image_library 查询。")
        }
        return lines.joined(separator: "\n")
    }

    /// image_library 工具的文本结果（对应 prompt.js libraryQueryText）
    static func libraryQueryText(category: String?, query: String?, id: String?,
                                 library: [StudioCategory: [LibraryEntry]]) -> String {
        let cats: [StudioCategory] = {
            if let c = category, let matched = StudioCategory.allCases.first(where: { $0.rawValue == c }) {
                return [matched]
            }
            return StudioCategory.allCases
        }()
        if let id, !id.isEmpty {
            for c in cats {
                guard let e = (library[c] ?? []).first(where: { $0.id == id || $0.name == id }) else { continue }
                var lines: [String] = ["\(c.label)「\(e.name)」 id: \(e.id)"]
                if !e.aliases.isEmpty { lines.append("别名：\(e.aliases.joined(separator: "、"))") }
                if !e.tags.isEmpty { lines.append("标签：\(e.tags.joined(separator: "、"))") }
                lines.append("参考图：\(e.images.count) 张")
                if !e.descriptionText.isEmpty { lines.append("外观描述：\(e.descriptionText)") }
                if !e.defaultOutfit.isEmpty { lines.append("默认服饰：\(e.defaultOutfit)") }
                if !e.traits.isEmpty { lines.append("神态特点：\(e.traits)") }
                if !e.situationOutfits.isEmpty {
                    lines.append("情境穿搭：" + e.situationOutfits.map { "\($0.key)→\($0.value)" }.joined(separator: "、"))
                }
                if !e.persona.isEmpty { lines.append("人设：\n\(e.persona)") }
                return lines.joined(separator: "\n")
            }
            return "没找到 id 或名字为「\(id)」的条目。"
        }
        let q = (query ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var out: [String] = []
        for c in cats {
            let hits = (library[c] ?? []).filter { e in
                q.isEmpty || ([e.id, e.name] + e.aliases + e.tags + [e.descriptionText])
                    .contains { $0.lowercased().contains(q) }
            }
            guard !hits.isEmpty else { continue }
            out.append("## \(c.label)（\(c.rawValue)）")
            for e in hits.prefix(60) {
                var line = "- \(e.name) [id: \(e.id)] \(e.images.count) 张图"
                if !e.tags.isEmpty { line += " · \(e.tags.joined(separator: "/"))" }
                if !e.descriptionText.isEmpty { line += " — \(oneLine(e.descriptionText, max: 80))" }
                out.append(line)
            }
            if hits.count > 60 { out.append("…还有 \(hits.count - 60) 项") }
        }
        if !out.isEmpty { return out.joined(separator: "\n") }
        return q.isEmpty ? "参考库是空的。" : "没有匹配「\(query ?? "")」的条目。"
    }
}
