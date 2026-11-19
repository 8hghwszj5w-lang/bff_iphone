# 分身（FenShen）— iPhone 上的「QQ 数字分身」

把 `~/Documents/deepseek-harness/qq` 的核心能力搬进一个原生 iOS App：
**人设大脑 + DeepSeek 流式对话 + 长期记忆（滚动摘要）+ 联网搜索工具**。
QQ/NapCat 那一层在 iOS 上无法复刻（那是 Linux QQ 容器），所以这个 App 直接作为「她」的对话端。

![模拟器截图](screenshot-simulator.png)

## 功能对照（qq 项目 → 本 App）

| qq 项目 | 本 App |
| --- | --- |
| `bridge/persona.md` 人设 | `PersonaStore`：设置 → 人设 子菜单内编辑 |
| `src/model/deepseek.js`（关思考） | `DeepSeekClient`：SSE 流式 + 异常/截断检测（不自动重试，避免重复输出和费用） |
| `src/model/tool-loop.js` 工具循环 | `ask()`：最多 3 轮 function calling |
| `src/tools/websearch.js` 联网搜索 | `WebSearchTool`：DuckDuckGo 免费无 key |
| `src/store/memory.js` 记忆 | `MemoryStore`：逐字窗口 + 滚动摘要 + 原子写（tmp+rename，坏文件留档） |
| `src/core/pipeline.js` 流水线 | `Pipeline`：收消息 → 记忆 → 模型(可调工具) → 清洗 → 落盘 |
| `src/config/schema.js` 配置 | `SettingsStore`：设置页（key / 模型 / 温度 / 窗口长度 / 搜索开关） |
| `src/core/usage.js` 用量 | `UsageStore` + 「用量信息」页（设置页置顶，累计/每日 token 统计，落盘 usage.json） |

## 使用

1. 用 Xcode 打开 `FenShen.xcodeproj`，插上 iPhone，Signing & Capabilities 里选你的个人 Team，⌘R 装到手机（免费账号 7 天有效期）。
2. 首次启动 → 右上角 ⚙️ → 「接口 → DeepSeek API」子菜单 → 填 API Key（可在里面点「发送一条测试消息」验证连通）。
3. 开聊。问她时事她会自己调 `web_search` 搜完再答；重启 App 记忆还在（存在 App Documents/memory/）。
   输入框左侧还有 **📷 图片** 和 **📎 文件** 按钮，全部按 DeepSeek 官方文档直传：
   - 图片（JPEG/PNG/GIF/WebP）：转 base64 `image_url` 内容块内联发送（`deepseek-flash` 支持图像理解；`v4-pro` 不支持，会给出明确提示）；
   - PDF/Word/PPT：经 Files API 以 `text_recognition` purpose 上传，对话里用 `file_id` 块引用；
   - 纯文本/代码/表格（XLSX）/电子书（EPUB/MOBI）：Files API `user_data` 直传；
   - 其他二进制类型：退回本地纯文本抽取（超 8000 字截断）。
   附件轻量记入记忆（file_id 不落盘），之后仍可追问本轮内容。
4. 设置页置顶还有：**用量信息**（累计/每日 token、估算花费、官方定价）、**充值**（拉起 Safari 收银台 + 微信/支付宝）、**记忆管理**（浏览窗口、编辑长期摘要、导出 JSON、分段清理）、**人设**（编辑她的性格和说话方式）、**聊天背景**（纯色/渐变/相册照片，选图后可拖动+双指缩放裁剪，支持全屏/3:4/1:1/16:9 比例，原图可反复重裁）、**每日日程**（对应桌面端 dsh-daily-schedule：今天/明天时间线编辑，自动生成"她此刻的生活背景"注入每轮对话，她还能用 schedule_adjust / schedule_view 两个工具自己记事和改计划，日程时间段还能写穿搭，生图时会沿用）、**生图工作室**（对应桌面端 dsh-image-studio，详见下节）。；以及**本机信息工具**：日历读写（calendar_read / calendar_create）、提醒事项读写（reminders_read / reminders_create）、备忘录搜索（notes_search，受系统能力限制只能查标题/摘要）。

## 生图工作室（对应桌面端 dsh-image-studio）

把桌面端「生图工作室」插件的核心能力搬进了 App：聊天里她会自己判断什么时候画一张，画完直接显示在气泡里（点开看大图，重启 App 图片还在）。

- **两个工具**：`image_generate`（画面描述 + 情境/神态/动作/镜头/光线关键词 + 参考库条目 → 组合参考图 → 生图 → 存沙盒）和 `image_library`（按关键词查参考库）。发图时机三档可选（手动/适中/主动），主动发图有分钟级冷却；用户明确要图时她会带 `user_requested` 绕开冷却。想在她画的那张基础上改，直接说「把刚才那张的 xxx 改成…」，她会把图片编号放进 extra_images。
- **参考库**：人物 / 服饰 / 场景 / 道具四个库，条目 = 文件夹（几张参考图 + entry.json）。设置页里可从相册导入、写外观描述；生图时参考图只负责「长得像」，姿势表情构图由文字关键词决定。目录布局与桌面端插件一致（`Documents/image-studio/library/…`），桌面端的素材文件夹可直接拷进沙盒复用。
- **关键词库**：情境 / 神态 / 动作 / 镜头 / 光线五组默认关键词（与桌面端 presets.json 同构，首次运行写入 `Documents/image-studio/presets.json`），设置页可增删改、恢复默认。情境会自动带出场景、服饰和光线。
- **日程穿搭联动**：每日日程的时间段可以写「穿什么」（schedule_adjust 也有 outfit / outfitNote 参数）；没指定服饰的生图会沿用她此刻的穿着，同一天出的图衣服对得上。
- **接口**：任何 OpenAI 兼容 `/v1/images` 接口（generations + edits）。带参考图时先走 `/images/edits`，中转不支持会自动降级为纯文字生成并在生成记录里注明「参考图未生效」。API Key 存 Keychain，设置页可「测试连接」列出生图模型。
- **生成记录**：`Documents/image-studio/history.jsonl`（一行一条，最多 2000 条），设置页可看缩略图、删（挪进 `.trash` 不硬删）、看大图；「试画一张」不走参考库组合，改完设置先快试一张再开聊。

## 重新生成工程（改了 project.yml 或增删文件后）

```bash
xcodegen generate
```

## 构建/测试命令（本机已验证）

```bash
# 模拟器构建（沙箱外正常 Xcode 环境直接 xcodebuild 即可）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project FenShen.xcodeproj -scheme FenShen \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath .build/DerivedData build
```

## 离线回归测试

测试使用临时目录、独立 UserDefaults 和模拟网络响应，不需要 API Key，也不调用收费接口。

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project FenShen.xcodeproj -scheme FenShen \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -derivedDataPath .build/DerivedData test
```

模拟器名称和系统版本请按本机已安装的设备调整。

2026-11-15 验证：Xcode 27.2 / iPhone 16 Pro 模拟器（iOS 18.6），应用与测试目标编译成功，34 项测试全部通过（存储 8、附件/裁剪/增量缓冲 9、网络 17）。如果代理执行沙箱阻止 Swift 宏插件启动，应授权在正常 Xcode 环境运行上述命令，不要修改项目设置来禁用安全机制。

### 本轮修复与优化

- 记忆与用量采用支持首次创建的原子写；损坏备份使用唯一名称，避免覆盖旧档。
- 修复记忆管理倒序列表删除错位，以及设置/背景/用量变化不及时刷新的问题。
- 流式回复合并为约 50ms 一次 UI 更新，复用未变化的气泡，取消逐 token 任务和重叠滚动动画。
- 修复流结束后迟到增量可能重复追加的问题；错误或断流不再按成功回复保存。
- 工具严格限制为最多三轮加一次无工具总结；请求直接 Codable 编码，移除多余 JSON 编解码和强制解包。
- 图片后台下采样、背景共享有界解码缓存；修复同文件重裁不刷新、裁剪预览与导出几何不一致。
- PDF 文本足够后停止提取后续页面；纯文本保留完整 UTF-8/二进制校验与 8000 字限制，超大纯文本仍需完整解码。
- 修复搜索结果 JSON 字段类型、特殊字符查询编码及 HTTP 错误处理。

性能收益来自减少刷新/解码/请求等具体工作量；尚未做真机 Instruments 对照，不承诺固定加速比例。

### 2026-11-17 第二节：通话与上传链路

- 修复 iOS 26 语音识别启动路径：`start()` 现在真的安装麦克风 tap 并启动 engine（此前只创建识别器，界面显示「收音中」却永远收不到声音）；启动失败会回滚已建资源。
- 修复旧版识别（iOS < 26）两句就哑：同文 `final` 不再被 partial 去重吞掉，说完一句自动换新识别请求，麦克风与 engine 不重启，可连续多轮；stop 后旧回调不能复活收听。
- 修复挂断后通话被「复活」：启动/回复任务都可取消，旧任务不能再把状态写回 listening；快速重拨会先等旧识别与音频清理完成，旧轮不会覆盖新轮状态。
- 同一时刻只允许一轮回复（同 tick 两个 final 不再并行启动）；本地 TTS 按 utterance 匹配并只结束一次续体，消除重复 resume 崩溃与等待任务泄漏。
- 云端 TTS 中途失败时先清掉本句残余音频再降级本地，正常云→本地切换等前一句播完，避免两路声音重叠。
- `awaitDrained` 改为回调唤醒，不再轮询；每片音频带 token，stop 后迟到回调不会误清新一轮；退出通话时真正停止并释放音频引擎。
- 附件上传改为后台分块写 multipart 临时文件后 `upload(fromFile:)`：不再在主线程额外复制整份附件，临时文件在成功、HTTP 错误、传输错误、取消路径都会清理；文档直接读 URL，不再先整份读入内存。
- 工具调用参数改为字典原位追加，长参数分片到达时不再反复复制已累积字符串。
- 图片 base64 与文本兜底抽取移到后台执行，取消能及时传导到上传/抽取。
- 修复「＋ → 相册」点击无效：相册选择器原先挂在会立即移除的附件面板上，现在挂到常驻视图。

离线回归：73 项测试通过（Keychain 在模拟器测试环境按既有逻辑跳过），覆盖新增的通话竞态、TTS 续体、多轮识别状态与上传清理用例。

### 2026-11-19 第三节：通话中闪退加固

真机上「通话中闪退」的共同根源是音频对象在环境突变后带病运行，CoreAudio 底层异常没有 Swift 栈可捕获，只能防：

- 来电/闹钟/Siri 打断、媒体服务失效：`AudioEnvironmentWatcher` 订阅系统通知，第一时间停 tap/engine 干净收尾，并以明确文案结束通话（此前引擎带失效对象继续跑，是底层异常崩溃的头号来源；`AudioEnvironmentPolicy` 纯逻辑矩阵离线可测）。
- 耳机/蓝牙插拔：收音中的会话自动停旧建新，跟随新路由重启；准备中或已挂断的变化被忽略（`setActive` 也可能触发路由通知，不能误杀启动中的会话），重启失败同样以明确文案结束通话。
- `installTap` 前校验麦克风输入格式：0Hz/0 声道格式会直接抛 ObjC 异常（无法 catch → 闪退），现在转换为可捕获错误，走既有的失败提示/回退路径。
- 识别内部失败（旧方案换句时识别不可用、新方案 analyzer/results 流中断）不再静默断麦：`SpeechSession.onInvalidated` 通知 VM 结束通话，杜绝「界面显示通话中、麦克风已死」的僵尸态。
- 对比模式在通话进行中不再切换音频会话类别（`PlaybackSessionConfig`）：改类别会让通话引擎的 tap + voice processing 失效，正是「通话中点开对比页就闪退/掉麦」的来源。
- 迟到环境事件由 `wantsCapture` 代次守卫拦截：挂断后到达的打断/路由通知不能复活通话或触发僵尸重启。

离线回归：105 项测试通过（含新增的环境事件策略矩阵与真实 NotificationCenter 投递用例；Keychain 在模拟器测试环境按既有逻辑跳过）。

### 2026-11-19 第四节：主动消息插件（心跳 + 闹铃）

让「她」不再只被动应答——用户不说话时也会自己开口。设置 → **主动消息** 可配置（默认开启，参数保守）。

**两条触发路径：**

- **闹铃机制（对话后续跟进）**：对话里模型自己判断要不要跟进，觉得有必要就调 `followup_set(minutes, intent, notify?)` 设一条「n 分钟后主动找他」的闹铃（`followup_cancel` 可反悔）。到点唤醒模型生成消息：气泡进聊天流 + 写入记忆 → 用户可接着回复，闭环完成。用户在到点前先开口 → 闹铃自动取消（闭环提前完成）；到点落在免打扰时段（默认 23:30–08:00，可改）→ 顺延到时段结束。
- **心跳机制（随机主动搭话）**：App 在前台时每隔 N 分钟（默认 10）tick 一次，按**情境加权概率**掷骰子——免打扰时段为 0、距上次主动消息不足冷却期（默认 45 分钟）为 0、用户刚说话不到 2 分钟为 0（别抢话）、距上次聊天越久概率越高（30 分钟爬满）、深夜减半。命中才真的调模型；模型也被允许回「skip」（这次不说），白花一次调用但不打扰。

**消息闭环**：所有主动消息 = assistant 气泡 + 写入记忆 + 计入用量统计，上下文连贯可继续对话。生成期间与对话回合互斥（她的消息永远排在当前这轮之后）。

**后台行为（iOS 硬限制的诚实说明）**：App 退后台约 30 秒后进程被系统冻结，无法到点现调 LLM。分级处理：

| 场景 | 行为 |
| --- | --- |
| 前台到点 | 现调模型生成 → 气泡直接进聊天（无通知） |
| 后台存活窗口（约 30 秒） | `beginBackgroundTask` 内立刻生成 → 本地通知带**真正文** |
| 已冻结 / 被杀 | 预约本地通知准点「敲门」；正文 = 她设闹铃时顺手写的 `notify`（没写则用兜底文案「她惦记着一件事，想跟你说两句」）；用户回 App 后 catch-up 现生成正文进聊天 |
| BGAppRefresh | 机会性补跑（系统不保证何时给时间，仅尽力） |

通知 category 带 `allowAnnouncement` + timeSensitive 中断级别：用户开启「设置 → Siri → 播报通知」且连着 AirPods 等设备时 Siri 会念出通知。挂起闹铃落盘（Documents/proactive/state.json），重启后依然兑现；生成失败自动推迟 10 分钟重试（最多 3 次）。

**文件结构（Sources/Proactive/）**：`ProactivePolicy.swift`（配置 + 免打扰/顺延/概率纯函数）、`ProactiveStore.swift`（配置存 UserDefaults + 状态原子写落盘）、`ProactiveEngine.swift`（定时器/生成管线/通知与 BG 衔接）、`ProactiveTools.swift`（followup_set / followup_cancel）、`ProactiveViews.swift`（设置子页）。工具挂进 Pipeline 的 alwaysTools；回合首尾经 `beginUserTurn/endUserTurn` 与引擎互斥。

## 目录

```
Sources/
  App/FenShenApp.swift      入口 + 全局装配（对应 core-runtime.js）
  Model/DeepSeekClient.swift  DeepSeek API + SSE + 工具调用循环
  Core/Stores.swift         设置 / 人设 / 记忆（原子写 + 损坏恢复）
  Core/Pipeline.swift       对话流水线 + 回复清洗
  Tools/Tools.swift         工具协议 + web_search（DuckDuckGo）
  Proactive/*.swift         主动消息插件（心跳 + 闹铃，见「第四节」）
  UI/ChatView.swift         聊天界面（气泡 / 流式打字机）
  UI/SettingsView.swift     设置页 + 人设编辑器
  Schedule/*.swift          每日日程（对应桌面端 dsh-daily-schedule）
  ImageStudio/*.swift       生图工作室（对应桌面端 dsh-image-studio）：模型 / 组合引擎 / 接口客户端 / 工具 / 设置页
```

## 想继续扩展？

- 多会话（像 qq 项目一人/一群一个记忆文件）：把 `MemoryStore` 按 contact key 实例化多个即可，存储层已按文件组织。
- 推送：接入 APNs 或复用 qq 项目的官方 bot 通道（`bin/notify.js`）给手机发提醒。
- 语音：加 Speech 框架做语音输入，AVSpeechSynthesizer 朗读回复。
