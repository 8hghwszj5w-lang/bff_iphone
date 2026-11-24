import XCTest
@testable import FenShen

/// 生图工作室离线测试：关键词 / 素材库 / 组合引擎 / 注入文本 / 存储 / 工具参数。
/// 网络全部走 URLProtocol 桩，不调真实接口、不花钱。
@MainActor
final class ImageStudioTests: XCTestCase {
    private var root: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-studio-tests-\(UUID().uuidString)", isDirectory: true)
        defaultsSuite = "ImageStudioTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        keychain = KeychainStore(service: defaultsSuite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuite)
        keychain.remove(account: ImageStudioStore.apiKeyAccount)
        StudioStubProtocol.handler = nil
    }

    // MARK: 基建

    private func makeStore(schedule: ScheduleStore? = nil,
                           session: URLSession = .shared) -> ImageStudioStore {
        var client = ImageStudioClient()
        client.session = session
        return ImageStudioStore(directory: root, schedule: schedule,
                                defaults: defaults, keychain: keychain, client: client)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudioStubProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    /// 1×1 PNG（文件头 \x89PNG，能被 sniffImage 认出）
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func stubPNGData() -> Data {
        Data(base64Encoded: pngBase64)!
    }

    nonisolated private static func generationsPayload(_ png: Data) -> Data {
        let payload: [String: Any] = ["data": [["b64_json": png.base64EncodedString()]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeLibrary() -> [StudioCategory: [LibraryEntry]] {
        var fish = LibraryEntry(id: "小鱼", category: .characters, isFolder: true, name: "小鱼")
        fish.aliases = ["鲸鱼娘", "鲸鲸"]
        fish.tags = ["主角"]
        fish.descriptionText = "深蓝色双马尾少女"
        fish.traits = "开心时尾巴会摇"
        fish.defaultOutfit = "居家针织服"
        fish.situationOutfits = ["工作学习": "通勤休闲装"]
        fish.images = ["front.png", "side.png"]
        var outfit = LibraryEntry(id: "居家针织服", category: .outfits, isFolder: true, name: "居家针织服")
        outfit.descriptionText = "米色宽松针织衫"
        outfit.images = ["01.png"]
        var dress = LibraryEntry(id: "外出连衣裙", category: .outfits, isFolder: true, name: "外出连衣裙")
        dress.images = ["01.png"]
        var bedroom = LibraryEntry(id: "卧室", category: .scenes, isFolder: true, name: "卧室")
        bedroom.descriptionText = "温馨的小卧室"
        bedroom.defaultOutfit = "睡裙"
        bedroom.images = ["01.png"]
        var street = LibraryEntry(id: "街道", category: .scenes, isFolder: true, name: "街道")
        street.images = ["01.png"]
        var mug = LibraryEntry(id: "马克杯", category: .props, isFolder: true, name: "马克杯")
        mug.images = ["01.png"]
        return [.characters: [fish], .outfits: [outfit, dress], .scenes: [bedroom, street], .props: [mug]]
    }

    // MARK: 关键词

    func testPresetLookupByAliasAndLooseMatch() {
        let presets = StudioDefaultPresets.presets
        XCTAssertEqual(presets.lookup(.situation, "宅家")?.name, "在家休息", "别名要能命中")
        XCTAssertEqual(presets.lookup(.expression, "气鼓鼓")?.name, "生气")
        XCTAssertEqual(presets.lookup(.shot, "POV")?.name, "第一人称")
        XCTAssertNil(presets.lookup(.pose, "完全没见过的词"), "不存在的词不硬凑")
        // 收录词的包含匹配（唯一时）
        XCTAssertEqual(presets.lookup(.light, "午后的阳光")?.name, "午后暖阳")
    }

    func testPresetsNormalizeDedupesAndKeepsOrder() {
        var raw = StudioPresets()
        raw.expression = [
            .init(name: "开心", prompt: "a"),
            .init(name: "开心", prompt: "b"),
            .init(name: "  ", prompt: "c"),
            .init(name: "难过", prompt: "d"),
        ]
        let normalized = StudioPresets.normalize(raw)
        XCTAssertEqual(normalized.expression.map(\.name), ["开心", "难过"])
    }

    // MARK: 素材库解析

    func testResolveRefByIdNameAndAlias() {
        let lib = makeLibrary()
        XCTAssertEqual(ImageStudioComposer.resolveRef(.characters, "鲸鲸", library: lib)?.id, "小鱼")
        XCTAssertEqual(ImageStudioComposer.resolveRef(.characters, "小鱼", library: lib)?.id, "小鱼")
        XCTAssertEqual(ImageStudioComposer.resolveRef(.outfits, "居家针织服", library: lib)?.id, "居家针织服")
        XCTAssertNil(ImageStudioComposer.resolveRef(.scenes, "不存在的场景", library: lib))
    }

    func testResolveRefAmbiguousLooseMatchReturnsNil() {
        var lib = makeLibrary()
        var extra = LibraryEntry(id: "小鱼干", category: .characters, isFolder: true, name: "小鱼干")
        extra.images = ["01.png"]
        lib[.characters]?.append(extra)
        // 「小鱼干二」同时松匹配「小鱼」「小鱼干」，唯一性不成立 → nil
        //（精确 id/名字命中优先是桌面端同款语义，所以这里不能拿「小鱼」测歧义）
        XCTAssertNil(ImageStudioComposer.resolveRef(.characters, "小鱼干二", library: lib))
        XCTAssertEqual(ImageStudioComposer.resolveRef(.characters, "鱼干", library: lib)?.id, "小鱼干")
    }

    func testMentionedInFindsCJKNameAndEnglishWordBoundary() {
        let lib = makeLibrary()
        XCTAssertEqual(ImageStudioComposer.mentionedIn(.characters, "鲸鲸今天很开心", library: lib).first?.id, "小鱼")
        XCTAssertNil(ImageStudioComposer.mentionedIn(.scenes, "她在房间里", library: lib).first, "「卧室」没被提到")
    }

    // MARK: 组合引擎

    func testKeywordExpansionAndSituationDefaults() {
        let config = StudioConfig()
        var args = StudioGenerateArgs()
        args.prompt = "画一张美美的"
        args.situation = "在家休息"
        args.expression = "害羞"
        args.characters = ["小鱼"]
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets)
        // 情境带出场景 / 服饰 / 光线
        XCTAssertEqual(plan.scene?.id, "卧室")
        XCTAssertTrue(plan.outfits.contains { $0.id == "居家针织服" })
        XCTAssertEqual(plan.keywords["light"], "午后暖阳")
        XCTAssertEqual(plan.keywords["expression"], "害羞")
        // 提示词分段
        XCTAssertTrue(plan.finalPrompt.contains("【画面】画一张美美的"))
        XCTAssertTrue(plan.finalPrompt.contains("【情境】在家休息：放松慵懒的居家氛围"))
        XCTAssertTrue(plan.finalPrompt.contains("【神态】脸颊泛起红晕"))
        XCTAssertTrue(plan.finalPrompt.contains("【光线氛围】午后温暖的阳光"))
        XCTAssertTrue(plan.finalPrompt.contains("【人物神态特点】"))
        XCTAssertTrue(plan.finalPrompt.contains("开心时尾巴会摇"))
        // 参考图：人物 2 张 + 服饰 1 + 场景 1 = 4
        XCTAssertEqual(plan.refs.count, 4)
        XCTAssertTrue(plan.finalPrompt.contains("【参考图说明（按上传顺序编号）】"))
    }

    func testOutfitFallbackTextOnlyWhenLibraryMissing() {
        let config = StudioConfig()
        var lib = makeLibrary()
        lib[.outfits] = []                     // 服饰库为空
        var args = StudioGenerateArgs()
        args.prompt = "在卧室里"
        args.situation = "在家休息"
        args.characters = ["小鱼"]
        let plan = ImageStudioComposer.compose(args, config: config, library: lib,
                                               presets: StudioDefaultPresets.presets)
        XCTAssertTrue(plan.finalPrompt.contains("【搭配】小鱼穿着居家针织服"))
        XCTAssertTrue(plan.notes.contains { $0.contains("只按文字描述") })
        // 场景默认服饰「睡裙」也落空 → 不应再有别的服饰参考
        XCTAssertTrue(plan.outfits.isEmpty)
    }

    func testExplicitOutfitWinsOverDefaults() {
        let config = StudioConfig()
        var args = StudioGenerateArgs()
        args.prompt = "在街上"
        args.outfits = ["外出连衣裙"]
        args.scene = "街道"
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets)
        XCTAssertEqual(plan.outfits.map(\.id), ["外出连衣裙"])
        XCTAssertEqual(plan.scene?.id, "街道")
    }

    func testScheduleOutfitLinkFollowsCurrentItem() {
        let config = StudioConfig()
        let schedule = StudioScheduleContext(characterName: "小鱼", start: "14:00", end: "16:00",
                                             activity: "逛街", outfit: "外出连衣裙", outfitNote: "外面罩了件防晒衫")
        var args = StudioGenerateArgs()
        args.prompt = "画一张美美的"
        args.expression = "开心"
        args.characters = ["小鱼"]
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets, schedule: schedule)
        XCTAssertTrue(plan.outfits.contains { $0.id == "外出连衣裙" }, "应沿用日程里此刻的穿搭")
        XCTAssertTrue(plan.notes.contains { $0.contains("沿用小鱼此刻身上穿的") })
        XCTAssertTrue(plan.finalPrompt.contains("小鱼的穿着细节：外面罩了件防晒衫"))
    }

    func testAutoMatchPicksUpMentionedCharacter() {
        let config = StudioConfig()
        var args = StudioGenerateArgs()
        args.prompt = "鲸鲸窝在沙发上"
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets)
        XCTAssertTrue(plan.characters.contains { $0.id == "小鱼" })
        XCTAssertTrue(plan.notes.contains { $0.contains("自动认出") })
    }

    private static func extraRef(_ id: String) -> StudioRef {
        StudioRef(kind: "extra", label: "上一张生成图（\(id)）")
    }

    func testReferenceBudgetAccountsForExtraCount() {
        var config = StudioConfig()
        config.compose.maxRefs = 3
        var args = StudioGenerateArgs()
        args.prompt = "改一张"
        args.characters = ["小鱼"]
        args.scene = "街道"                     // 预算不够时它会被落选并记进说明
        let extra = StudioExtraInput(raw: "img-old", ref: Self.extraRef("img-old"))
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets, extras: [extra])
        // 上一张图占 1 张 → 条目只剩 2 张预算：fish front + outfit 01（无余量给场景）
        XCTAssertEqual(plan.refs.filter { $0.kind == "entry" }.count, 2)
        XCTAssertTrue(plan.notes.contains { $0.contains("参考图超过上限") }, "notes=\(plan.notes) refs=\(plan.refs.count) chosenScene=\(plan.scene?.id ?? "nil")")
    }

    func testExtraImagesNumberingAndPromptLine() {
        var args = StudioGenerateArgs()
        args.prompt = "把背景换成海边"
        args.characters = ["小鱼"]
        args.scene = "街道"
        let extra = StudioExtraInput(raw: "img-20261119-120000-abcd", ref: Self.extraRef("img-20261119-120000-abcd"))
        let plan = ImageStudioComposer.compose(args, config: StudioConfig(), library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets, extras: [extra])
        // 上一张图排在最前，编号图1；条目从图2开始（原来 Store 前插但 compose 的编号从 1 起 → 整体错位）
        XCTAssertEqual(plan.refs.first?.kind, "extra")
        XCTAssertTrue(plan.finalPrompt.contains("图1：上一张生成图（img-20261119-120000-abcd）——在它的基础上按要求修改，没提到要改的部分保持不变。"),
                      plan.finalPrompt)
        XCTAssertTrue(plan.finalPrompt.contains("图2–3：人物「小鱼」"), plan.finalPrompt)
        let ordered = plan.refs.filter { $0.kind == "entry" }
        XCTAssertEqual(ordered.first?.entryId, "小鱼")
        XCTAssertEqual(ordered.first?.file, "front.png", "人物两张参考图都该保留")
    }

    func testUnresolvedExtraDoesNotConsumeBudget() {
        var config = StudioConfig()
        config.compose.maxRefs = 3
        var args = StudioGenerateArgs()
        args.prompt = "改一张"
        args.characters = ["小鱼"]
        args.scene = "街道"
        let bad = StudioExtraInput(raw: "img-不存在", ref: nil)
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets, extras: [bad])
        // 解析不了的引用不占预算：条目照旧挑满 3 张
        XCTAssertEqual(plan.refs.count, 3)
        XCTAssertTrue(plan.unresolved.contains("参考图「img-不存在」"))
        XCTAssertFalse(plan.finalPrompt.contains("在它的基础上按要求修改"), "没解析成功就不该有改图说明")
    }

    func testScheduleSceneMismatchSkipsOutfitLink() {
        // 桌面 schedule-link.js:90-93：画的场景和日程此刻的 scene 不一致，就不沿用日程穿搭
        let schedule = StudioScheduleContext(characterName: "小鱼", start: "14:00", end: "16:00",
                                             activity: "在家休息", outfit: "外出连衣裙",
                                             outfitNote: "", scene: "卧室")
        var args = StudioGenerateArgs()
        args.prompt = "在街上"
        args.characters = ["小鱼"]
        args.scene = "街道"
        let mismatch = ImageStudioComposer.compose(args, config: StudioConfig(), library: makeLibrary(),
                                                   presets: StudioDefaultPresets.presets, schedule: schedule)
        XCTAssertFalse(mismatch.outfits.contains { $0.id == "外出连衣裙" })
        XCTAssertFalse(mismatch.notes.contains { $0.contains("沿用") })

        args.scene = "卧室"   // 场景一致 → 沿用
        let matched = ImageStudioComposer.compose(args, config: StudioConfig(), library: makeLibrary(),
                                                  presets: StudioDefaultPresets.presets, schedule: schedule)
        XCTAssertTrue(matched.outfits.contains { $0.id == "外出连衣裙" })
        XCTAssertTrue(matched.notes.contains { $0.contains("沿用") })
    }

    func testAspectNormalization() {
        XCTAssertEqual(ImageStudioComposer.normalizeAspect("3：4", fallback: "1:1"), "3:4")
        XCTAssertEqual(ImageStudioComposer.normalizeAspect("800*600", fallback: "1:1"), "800x600")
        XCTAssertEqual(ImageStudioComposer.normalizeAspect("随便", fallback: "3:4"), "3:4")
        var config = StudioConfig()
        var args = StudioGenerateArgs()
        args.prompt = "x"
        args.aspect = "16:9"
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets)
        XCTAssertEqual(plan.aspect, "16:9")
    }

    func testUnresolvedEntriesAreReported() {
        let config = StudioConfig()
        var args = StudioGenerateArgs()
        args.prompt = "画一张"
        args.characters = ["不存在的人"]
        args.scene = "火星表面"
        let plan = ImageStudioComposer.compose(args, config: config, library: makeLibrary(),
                                               presets: StudioDefaultPresets.presets)
        XCTAssertEqual(plan.unresolved.count, 2)
    }

    // MARK: 注入文本 / 查询

    func testGuideTextContainsKeywordsCatalogAndCooldown() {
        var config = StudioConfig()
        config.policy.cooldownMin = 5
        let text = ImageStudioGuide.guideText(config: config,
                                              library: makeLibrary(),
                                              presets: StudioDefaultPresets.presets)
        XCTAssertTrue(text.contains("# 生图（image_generate）"))
        XCTAssertTrue(text.contains("至少间隔 5 分钟"))
        XCTAssertTrue(text.contains("何时发图"))
        XCTAssertTrue(text.contains("情境（situation）："))
        XCTAssertTrue(text.contains("在家休息"))
        XCTAssertTrue(text.contains("人物（characters）："))
        XCTAssertTrue(text.contains("小鱼（又名 鲸鱼娘/鲸鲸）"))
    }

    func testGuideTextEmptyWhenDisabled() {
        var config = StudioConfig()
        config.enabled = false
        let text = ImageStudioGuide.guideText(config: config,
                                              library: makeLibrary(),
                                              presets: StudioDefaultPresets.presets)
        XCTAssertTrue(text.isEmpty)
    }

    func testLibraryQueryTextByIdAndSearch() {
        let lib = makeLibrary()
        let byId = ImageStudioGuide.libraryQueryText(category: nil, query: nil, id: "小鱼", library: lib)
        XCTAssertTrue(byId.contains("外观描述：深蓝色双马尾少女"))
        XCTAssertTrue(byId.contains("神态特点：开心时尾巴会摇"))
        XCTAssertTrue(byId.contains("情境穿搭：工作学习→通勤休闲装"))
        let search = ImageStudioGuide.libraryQueryText(category: "outfits", query: "针织", id: nil, library: lib)
        XCTAssertTrue(search.contains("居家针织服"))
        XCTAssertFalse(search.contains("小鱼"), "category 过滤后不该串库")
        let miss = ImageStudioGuide.libraryQueryText(category: nil, query: "查无此项", id: nil, library: lib)
        XCTAssertTrue(miss.contains("没有匹配"))
    }

    // MARK: 存储

    func testFirstRunWritesDefaultPresetsAndApiKeyGoesToKeychain() throws {
        let store = makeStore()
        // presets.json 首次运行写入默认值
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("presets.json").path))
        XCTAssertFalse(store.presets.situation.isEmpty)
        // Key 优先写 Keychain；Keychain 写失败（测试宿主可能缺授权组）时退回 UserDefaults，
        // 两种情况都要求「不丢 Key」且不落 config.json
        store.apiKey = "sk-test-123"
        let stored = keychain.string(account: ImageStudioStore.apiKeyAccount)
            ?? defaults.string(forKey: "studio.apiKey")
        XCTAssertEqual(stored, "sk-test-123")
        // config 持久化
        store.config.api.model = "stub-image"
        let reloaded = ImageStudioStore(directory: root, defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.config.api.model, "stub-image")
        XCTAssertEqual(reloaded.apiKey, "sk-test-123")
    }

    func testCreateEntryScanAndDeleteMovesToTrash() throws {
        let store = makeStore()
        let entry = try store.createEntry(category: .characters, name: "测试角色",
                                          aliases: ["小白"], tags: ["测试"],
                                          description: "一只测试用的小白鼠", images: [stubPNGData()])
        XCTAssertEqual(entry.name, "测试角色")
        XCTAssertEqual(entry.images.count, 1)
        XCTAssertEqual(entry.coverFile, "01.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.entryImageURL(entry, file: "01.png").path))
        XCTAssertTrue(store.library[.characters]?.contains { $0.id == "测试角色" } ?? false)

        store.deleteEntry(entry)
        XCTAssertTrue(store.library[.characters]?.contains { $0.id == "测试角色" } != true)
        let trash = try XCTUnwrap(try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(".trash/characters"), includingPropertiesForKeys: nil))
        XCTAssertFalse(trash.isEmpty, "删除应挪进 .trash，不做硬删除")
    }

    // MARK: 生成（离线桩）

    func testGenerateOfflineSuccessWritesOutputsAndHistory() async throws {
        let png = stubPNGData()
        StudioStubProtocol.handler = { request in
            guard request.url?.path.hasSuffix("/images/generations") == true else { return (404, Data()) }
            return (200, Self.generationsPayload(png))
        }
        let store = makeStore(session: stubSession())
        store.apiKey = "sk-stub"
        store.config.api.baseURL = "https://stub.invalid"
        store.config.api.model = "stub-image"
        let epochBefore = store.generationEpoch

        var args = StudioGenerateArgs()
        args.prompt = "画一张美美的"
        args.expression = "害羞"
        let record = try await store.generate(args, source: "tool")

        XCTAssertEqual(record.status, "done")
        XCTAssertEqual(record.model, "stub-image")
        XCTAssertTrue(record.files.first?.hasSuffix(".png") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.outputURL(record.files[0]).path))
        XCTAssertEqual(store.findHistory(record.id)?.status, "done")
        XCTAssertFalse(store.recordsSince(epochBefore).isEmpty, "生成的图要进本轮日志供气泡取用")
        XCTAssertNotNil(store.lastShotAt, "工具出图后要记冷却时间")
    }

    func testGenerateCooldownBlocksUnrequestedToolShot() async throws {
        let png = stubPNGData()
        StudioStubProtocol.handler = { _ in (200, Self.generationsPayload(png)) }
        let store = makeStore(session: stubSession())
        store.apiKey = "sk-stub"
        store.config.api.baseURL = "https://stub.invalid"
        store.config.policy.cooldownMin = 3

        var first = StudioGenerateArgs()
        first.prompt = "第一张"
        _ = try await store.generate(first, source: "tool")

        var second = StudioGenerateArgs()
        second.prompt = "第二张"
        do {
            _ = try await store.generate(second, source: "tool")
            XCTFail("冷却期内应拒绝")
        } catch let error as StudioError {
            XCTAssertTrue(error.message.contains("冷却"))
        }
        // 用户明确要图时不受限
        second.userRequested = true
        let record = try await store.generate(second, source: "tool")
        XCTAssertEqual(record.status, "done")
    }

    func testGenerateFriendlyErrorOn402() async throws {
        StudioStubProtocol.handler = { _ in
            let body = try! JSONSerialization.data(withJSONObject: ["error": ["message": "no balance"]])
            return (402, body)
        }
        let store = makeStore(session: stubSession())
        store.apiKey = "sk-stub"
        store.config.api.baseURL = "https://stub.invalid"
        var args = StudioGenerateArgs()
        args.prompt = "画一张"
        do {
            _ = try await store.generate(args, source: "tool")
            XCTFail("402 应抛错")
        } catch let error as StudioError {
            XCTAssertTrue(error.message.contains("余额不足"))
            XCTAssertTrue(error.message.contains("no balance"))
        }
        XCTAssertEqual(store.recentRecords.first?.status, "failed", "失败也要落一条历史")
    }

    func testEditsFallbackNoteWhenEndpointMissing() async throws {
        let png = stubPNGData()
        StudioStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/images/edits") { return (404, Data()) }
            return (200, Self.generationsPayload(png))
        }
        let store = makeStore(session: stubSession())
        store.apiKey = "sk-stub"
        store.config.api.baseURL = "https://stub.invalid"
        // 先造一条带图的历史供 extra_images 引用
        let seed = try store.createEntry(category: .props, name: "参考图", aliases: [], tags: [],
                                         description: "", images: [stubPNGData()])
        var args = StudioGenerateArgs()
        args.prompt = "在参考图基础上改"
        args.props = [seed.id]
        let record = try await store.generate(args, source: "tool")
        XCTAssertEqual(record.status, "done")
        XCTAssertTrue(record.notes.contains { $0.contains("已降级为纯文字生成") },
                      "edits 不可用要降级并记 note")
        // 参考图确实带上过（refs 里应有道具条目）
        XCTAssertTrue(record.refs.contains { $0.kind == "entry" && $0.category == "props" })
    }

    func testDeleteRecordMovesFilesToTrash() async throws {
        let png = stubPNGData()
        StudioStubProtocol.handler = { _ in (200, Self.generationsPayload(png)) }
        let store = makeStore(session: stubSession())
        store.apiKey = "sk-stub"
        store.config.api.baseURL = "https://stub.invalid"
        var args = StudioGenerateArgs()
        args.prompt = "画一张"
        let record = try await store.generate(args, source: "ui")
        let fileURL = store.outputURL(record.files[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.deleteRecord(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(store.findHistory(record.id)?.status, "deleted")
        let trash = try XCTUnwrap(try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(".trash/outputs"), includingPropertiesForKeys: nil))
        XCTAssertTrue(trash.contains { $0.lastPathComponent == fileURL.lastPathComponent })
    }

    // MARK: 日程联动 / 兼容

    func testScheduleContextReadsCurrentOutfit() throws {
        let scheduleDir = root.appendingPathComponent("schedule", isDirectory: true)
        let schedule = ScheduleStore(directory: scheduleDir)
        let today = ScheduleStore.dateKey(for: Date())
        let hour = Calendar.current.component(.hour, from: Date())
        let start = ScheduleItem.clock(minutes: max(0, (hour - 1) * 60))
        let end = ScheduleItem.clock(minutes: min(1440, (hour + 1) * 60))
        schedule.saveDay(DaySchedule(date: today, items: [
            ScheduleItem(start: start, end: end, activity: "逛街", location: "商场", detail: nil,
                         outfit: "外出连衣裙", outfitNote: "扎了双马尾"),
        ]))
        let store = makeStore(schedule: schedule)
        let context = try XCTUnwrap(store.scheduleContext(), "此刻那段有穿搭，联动应生效")
        XCTAssertEqual(context.outfit, "外出连衣裙")
        XCTAssertEqual(context.outfitNote, "扎了双马尾")
        // 关掉联动后不再读
        store.config.compose.followSchedule = false
        XCTAssertNil(store.scheduleContext())
    }

    func testScheduleItemDecodesLegacyJSONWithoutOutfitFields() throws {
        let legacy = #"{"start":"09:00","end":"10:00","activity":"写代码","location":"公司"}"#
        let item = try JSONDecoder().decode(ScheduleItem.self, from: Data(legacy.utf8))
        XCTAssertNil(item.outfit)
        XCTAssertNil(item.outfitNote)
        let roundTrip = try JSONDecoder().decode(ScheduleItem.self, from: JSONEncoder().encode(
            ScheduleItem(start: "09:00", end: "10:00", activity: "写代码", location: nil, detail: nil,
                         outfit: "通勤装", outfitNote: nil)))
        XCTAssertEqual(roundTrip.outfit, "通勤装")
    }

    // MARK: 记忆 / 工具 / 客户端

    func testMemoryEntryStoresImagePathsAndStudioBlock() {
        let memory = MemoryStore(directory: root.appendingPathComponent("memory", isDirectory: true))
        memory.append(role: "assistant", content: "画好啦", maxHistory: 40, images: ["2026-11/img-x.png"])
        XCTAssertEqual(memory.record.entries[0].images, ["2026-11/img-x.png"])
        XCTAssertTrue(memory.exportText.contains("img-x.png"))
        let messages = memory.contextMessages(persona: "人设", scheduleBlock: "日程块", studioBlock: "生图块")
        XCTAssertTrue(messages[0].content.contains("日程块"))
        XCTAssertTrue(messages[0].content.contains("生图块"))
    }

    func testImageGenerateToolParsesArgumentsTolerantly() {
        let json = #"{"prompt":"画一张","characters":["鲸鲸"],"outfits":"居家针织服, 围巾","user_requested":true}"#
        let args = ImageGenerateTool.parseArguments(json)
        XCTAssertEqual(args.prompt, "画一张")
        XCTAssertEqual(args.characters, ["鲸鲸"])
        XCTAssertEqual(args.outfits, ["居家针织服", "围巾"], "逗号分隔字符串要拆成数组")
        XCTAssertTrue(args.userRequested)
        let broken = ImageGenerateTool.parseArguments("不是 JSON")
        XCTAssertTrue(broken.prompt.isEmpty)
    }

    func testImageGenerateToolSuccessTextMentionsIdAndExtraImages() throws {
        let record = ImageRecord(id: "img-20261119-120000-abcd", at: Date(), source: "tool",
                                 status: "done", prompt: "画一张", caption: "",
                                 finalPrompt: "", aspect: "3:4",
                                 refs: [ImageRefSummary(kind: "entry", category: "characters",
                                                        id: "小鱼", name: "小鱼", count: 2)],
                                 keywords: ["expression": "害羞"],
                                 notes: ["从画面描述里自动认出"], unresolved: [],
                                 model: "stub-image", files: ["2026-11/img-x.png"], ms: 42_000)
        let text = ImageGenerateTool.successText(record)
        XCTAssertTrue(text.contains("img-20261119-120000-abcd"))
        XCTAssertTrue(text.contains("人物「小鱼」×2"))
        XCTAssertTrue(text.contains("神态「害羞」"))
        XCTAssertTrue(text.contains("extra_images"))
    }

    func testClientPixelSizeAndErrorMapping() throws {
        XCTAssertEqual(ImageStudioClient.pixelSize("3:4"), "1024x1536")
        XCTAssertEqual(ImageStudioClient.pixelSize("16:9"), "1536x1024")
        XCTAssertEqual(ImageStudioClient.pixelSize("1:1"), "1024x1024")
        XCTAssertEqual(ImageStudioClient.pixelSize("1024x512"), "1024x512")
        XCTAssertNil(ImageStudioClient.pixelSize("乱写"))
        XCTAssertEqual(try ImageStudioClient.v1Base("https://x.cn"), "https://x.cn/v1")
        XCTAssertEqual(try ImageStudioClient.v1Base("https://x.cn/"), "https://x.cn/v1")
        XCTAssertEqual(try ImageStudioClient.v1Base("https://x.cn/compatible-mode/v1"), "https://x.cn/compatible-mode/v1")
        let error = ImageStudioClient.readError(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        XCTAssertTrue(error.message.contains("API Key 无效"))
        XCTAssertTrue(error.message.contains("bad key"))
    }

    func testListModelsPicksImageCapableEntries() async throws {
        StudioStubProtocol.handler = { request in
            guard request.url?.path.hasSuffix("/models") == true else { return (404, Data()) }
            let body = try! JSONSerialization.data(withJSONObject: [
                "data": [
                    ["id": "stub-image", "capabilities": ["image"]],
                    ["id": "deepseek-chat"],
                    ["id": "flux-pro"],
                ],
            ])
            return (200, body)
        }
        var client = ImageStudioClient()
        client.session = stubSession()
        var config = StudioConfig()
        config.api.baseURL = "https://stub.invalid"
        config.api.apiKey = "sk-stub"
        let models = try await client.listModels(config: config)
        XCTAssertEqual(models, ["stub-image", "flux-pro"])
    }
}

// MARK: - URLProtocol 桩

/// 生图接口离线桩：按 handler 返回状态码与响应体
final class StudioStubProtocol: URLProtocol {
    static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
