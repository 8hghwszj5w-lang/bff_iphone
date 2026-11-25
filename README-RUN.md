# 语音通话运行手册（README-RUN）

聊天页右上角 📞 进入的语音通话：你说话 → 系统语音识别转文字 → 走同一套 Pipeline（人设 + 记忆 + DeepSeek）→ 回复念给你听，循环到挂断。
状态机：`idle → preparing → listening ⇄ thinking → speaking →（播完或被打断）→ listening`。

## 1. 这是什么：两条 TTS 路径

| 路由（Picker 显示名） | 链路 | 说明 |
| --- | --- | --- |
| 本地语音（`local`） | 本地 STT → Pipeline → AVSpeechSynthesizer | 优先 `premium > enhanced > 默认` 中文音色（[TTSEngines.swift](Sources/Call/TTSEngines.swift)）。enhanced/premium 需在手机 **设置 → 辅助功能 → 朗读内容 → 声音** 里下载过才生效，否则用系统默认音色 |
| DeepSeek 语音（`deepSeek`） | 本地 STT → Pipeline 流式文本 → `POST /v1/tools/tts` → 流式 PCM 播放 | 响应体为 24kHz / 16bit / 单声道 PCM，边合成边播（[StreamingAudioPlayer.swift](Sources/Call/StreamingAudioPlayer.swift)）；音色 `stella`（默认女声）/ `tide`（男声），`filter_markdown` 已开 |
| 自动降级（`autoFallback`，默认） | 先试云端，失败自动换本地 | 无感降级：切换当句起用本地语音并提示一次；**30 秒冷却**后自动重试云端（自愈），手动切路由会立即清冷却 |

LLM 流式文本按句末标点切句（`SentenceSplitter`，数字小数点如 3.14 不切），TTS 按句合成才能「边生成边说话」。

## 2. 配置 API Key

1. App 内：**设置（右上角 ⚙️）→ 接口 → DeepSeek API** → 填入 `sk-…`，可点「发送一条测试消息」验证连通。Key 在 [platform.deepseek.com](https://platform.deepseek.com) 申请。
2. Key 自动存入 **Keychain**（[KeychainStore.swift](Sources/Call/KeychainStore.swift)），不落 UserDefaults、不硬编码；Keychain 写失败的极端情况退回 UserDefaults，宁可降级也不丢 Key。
3. 旧版本存在 UserDefaults 的 Key 首次启动**自动迁移**进 Keychain 并从明文存储删除（[Stores.swift](Sources/Core/Stores.swift) 的 `apiKey` init/didSet）。
4. TTS 与对话共用同一个 Key；自定义 baseURL 时 TTS 端点自动推导为 `{baseURL}/v1/tools/tts`（注意带 `/v1`，与 `/files` 的根路径不同）。

## 3. 真机运行步骤

| 步骤 | 说明 |
| --- | --- |
| 1. 打开工程 | Xcode 打开 `FenShen.xcodeproj`（改了 `project.yml` 或增删文件后先 `xcodegen generate`） |
| 2. 签名 | Signing & Capabilities 选你的个人 Team（免费账号 7 天有效期，到期重装） |
| 3. 安装运行 | 插上 iPhone，⌘R |
| 4. 授权 | 首次进入通话点「开始」会**依次弹两个授权框**：麦克风 + 语音识别。语音识别授权仅 **iOS < 26** 需要（iOS 26 的新 SpeechAnalyzer API 不需要该权限） |
| 5. 下载识别模型 | **iOS 26+** 首次使用 SpeechAnalyzer 会下载中文识别模型（需网络），装完识别更快且可离线 |

权限声明见 `project.yml`：`NSMicrophoneUsageDescription`（语音通话需要使用麦克风听你说话）、`NSSpeechRecognitionUsageDescription`（把你说的话转成文字，便于 AI 理解与回复）。模拟器能跑，但麦克风/识别体验与真机差异大，验收请用真机。

## 4. 功能操作

| 操作 | 入口与行为 |
| --- | --- |
| 进入通话 | 聊天页右上角 **📞**（[ChatView.swift](Sources/UI/ChatView.swift) 拉起 [PhoneView.swift](Sources/UI/PhoneView.swift)） |
| 挂断 | 通话页左上角「挂断」，或退出页面；录音、TTS、网络任务全部清理 |
| 切换 TTS 路由 | 通话页路由 **Picker**（本地语音 / DeepSeek 语音 / 自动降级）。**切换即时生效**：下一句就用新路径，不用重挂通话；选择持久化，下次通话仍生效 |
| 对比模式 | 通话页对比模式入口：**同一段文本双路径各合成一遍**，对比首包/总耗时，并可对两条路径各打 **1–5 星**。记录写入 `Documents/call_comparisons.json`（保留最近 50 条） |
| 打断她 | 她说话期间你直接开口，即停（详见第 6 节） |

## 5. 埋点指标含义

每轮对话记录到 `Documents/call_metrics.json`（原子写，只留最近 200 轮），字段见 [CallCore.swift](Sources/Call/CallCore.swift) 的 `TurnMetrics`：

| 字段 | 含义 |
| --- | --- |
| `llmTTFTMs` | **LLM 首字**：用户说完 → 首个文本增量到达 |
| `ttsFirstPacketMs` | **TTS 首包**（仅云端路径；本地路径无此概念，为 `null`）：该句音频首包到达 |
| `e2eFirstAudioMs` | **端到端首音**：用户说完 → 听到第一个声音。**体验上最重要的数字**，本地取合成首声回调、云端取播放器首个 buffer，只记最早的 |
| `totalMs` | 整轮耗时 |
| `route` / `actualPath` | 请求的路由 / 实际走的路径：`cloud` · `local` · `local-fallback` |
| `interrupted` / `degraded` | 是否被你开口打断 / 云端失败是否降级到本地 |

## 6. 音频链路说明

- **会话配置**（[CallViewModel.swift](Sources/Call/CallViewModel.swift)）：`AVAudioSession` `.playAndRecord` + `mode: .voiceChat` + `[.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]`（`.allowBluetooth` 自 iOS 8 起改名 `allowBluetoothHFP`）——录音 + 外放、蓝牙耳机可用、自动压低他人背景音。另锁定 `preferredSampleRate = 48kHz`、`preferredIOBufferDuration = 5ms`：前者避免 TTS 开播/停播引起硬件采样率重协商，后者压低收音与播放两端的 IO 延迟。**激活/去激活在后台线程同步执行**（`AudioSessionActivation`，见 [CallCore.swift](Sources/Call/CallCore.swift)）：主线程同步 `setActive` 在路由协商时可能卡 UI 数百毫秒（系统警告）；iOS 27 新增的异步 API 在 27.3 beta 上完成回调不触发会永久挂起通话，故不采用——后台同步调用不卡主线程、必然返回，全系统版本同一行为。
- **播放管线格式（2026-11-20 重新验证）**：云端 TTS 的原始 PCM 是 24kHz/16bit/单声道。两条经验证的硬约束：① `AVAudioPlayerNode` **不做位深/采样率转换**——调度 buffer 必须与播放节点连接格式一致，否则 int16 字节被按 float32 解释（离线渲染测试抓到 10^38 级垃圾值 = 真机杂音）；② mixer 输入总线**不接受 int16**（连接报 `kAudioUnitErr_FormatNotSupported -10868`）。所以 `play()` 先把 int16 转成 float32、播放节点按 **float32@24kHz/单声道** 连接（与 buffer 完全一致、零转换），采样率到 48kHz 的转换由 mixer 逐路完成。`PlaybackGraphRenderingTests` 用离线渲染对输出做样本级回归（0.5s 440Hz 正弦 → 幅度/零交叉校验），改动该链路会直接失败。
- **单引擎播放（2026-11-20 修复）**：TTS 播放节点接入**通话会话自己的 `AVAudioEngine`**（`SpeechSession.sharedAudioEngine`），不再自建第二个引擎。双引擎在 voice-processing 会话里会争抢 IO：合成音听不到、`dataPlayedBack` 不触发导致 `awaitDrained` 卡死（表现为多轮对话不可用）、引擎反复启停爆音。播放节点与麦克风同一引擎后，系统回声消除还能把 TTS 外放正确计入参考信号（防自听触发打断）。
- **识别输入格式协商（iOS 26 `SpeechAnalyzer`）**：分析器有两条硬约束——① `AnalyzerInput` **只接受 16bit 整型 PCM**（真机断言「Audio sample data must be 16-bit signed integers」，喂 float32 是不可捕获的硬 trap）；② **模型按采样率查找**，喂 48kHz 会报「Model not available for LiveTranscription zh_CN 48,000」（zh_CN 模型为 16kHz）。启动时先向分析器协商输入格式（`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`），tap 保持原生格式收音，`TapBufferConditioner` 用 `AVAudioConverter` 一步完成 float32→int16 + 48k→16k 重采样，空帧/非法格式丢弃。识别模型未装好（`AssetInventory` 状态为 downloading/supported）时先等待安装完成再启动分析器。
- **识别结果语义（2026-11-20 修复「多轮对话不可用」）**：`SpeechTranscriber` 按**句段（phrase）**产出结果（Apple 文档：「The phrases are sent in order」）——同一句段会多次重发 volatile 文本（越来越准），`isFinal` 标记该句段定稿，`text` 是该句段**自己的**文本而不是全场累计。旧实现按「累计文本」做前缀差分，第二段起文本比累计值短会被丢弃／被截错，所以第一轮之后再说话没有任何反应。现在按 `isFinal` 直接分发：volatile → `.partial`（实时字幕/打断），final → `.final`（VM 开新一轮）。
- **回声消除**：输入节点 `setVoiceProcessingEnabled(true)` 启用系统级 voice processing，TTS 外放不会被当成你在说话——所以 **speaking 期间识别一直开着**，为打断做准备。
- **打断（barge-in）**：speaking 期间出现新的非空 partial（句段级文本 = 用户又开口）→ 立即**取消 LLM 网络流 + 取消 TTS 流 + 清空播放器已入队的音频** → 短暂 `interrupted` 后直接回 `listening` 收音。若整句 final 在她说话期间到达（没等到 partial），同样先打断再开新一轮，不丢话。
- 打断粒度见第 7 节限制：从你开口到她停声，延迟约等于一个识别帧。
- **云端 TTS 流式性能**：delegate 分块直出（不再逐字节异步迭代），首包攒够 1024 字节（≈21ms 音频）即交播放器，后续按 4096 批量；奇数网络分片按 16bit 采样对齐拼接，句间复用同一连接池。

## 7. 已知限制（诚实清单）

| 限制 | 说明 |
| --- | --- |
| 打断只到「整帧」粒度 | 靠识别 partial 帧到达触发，不是逐采样静音检测；开口到停声 ≈ 一个识别帧的延迟 |
| DeepSeek TTS 不支持语速调节与断点续传 | 官方接口限制；打断只能直接取消整个请求，该句不会续播 |
| iOS < 26 的 SFSpeechRecognizer | 单次识别约 1 分钟上限，且**需联网**；实现里每句说完换新 request 续听，长段独白可能中断 |
| 模拟器语音体验与真机有差异 | 模拟器麦克风/识别链路与真机不同，功能和延迟结论以真机为准 |
| Files 与 TTS 音频在账号下永久有效 | 上传的文件、合成的音频留在 DeepSeek 账号下不会自动过期，**需自行到平台清理** |
| 云端 TTS 中途断流视为失败 | 按官方文档要求，实现校验响应字节数是否达到 Content-Length；断流时**整句作废**、该句自动降级本地重念（不会念半截） |

## 8.5 本机数据权限（日历 / 提醒事项 / 备忘录）

- 首次让 AI 查日历/提醒事项时会弹系统授权框；拒绝后工具会返回设置路径的指引文案。
- 权限声明（project.yml）：日历完全访问 + 只写、提醒事项完全访问、相机、麦克风、语音识别。
- 日历/提醒事项走 EventKit（可读可写）；**备忘录没有公开 API**，只能经 Spotlight 搜标题/摘要（搜不到全文，新记的或锁定的搜不到，写入需在系统 App 操作）。
- `calendar_read` 默认看从 `day` 起的三天（`day` = today / tomorrow / yesterday）；只要某一天传 `days: 1`，看一周传 `days: 7`，最多 `days: 30`，多天结果按天分组、空的日子也会写出来。
- 模拟器上日历/提醒事项默认没有数据，返回空列表是正常的。

## 8. 故障排查

| 症状 | 原因与处理 |
| --- | --- |
| 首次通话没弹授权框 | 之前拒绝过：到 **设置 → 隐私与安全性 → 麦克风 / 语音识别** 手动允许「分身」 |
| 提示 401（或测试消息失败） | Key 错/失效：设置 → 接口 → DeepSeek API 重填，点「发送一条测试消息」验证 |
| 提示 429 | TTS 并发超上限：稍后再说；autoFallback 已自动降级本地，不阻塞通话 |
| 提示 503 | 服务繁忙：稍后重试；autoFallback 期间自动走本地 |
| iOS 26 识别模型下载失败 | 换网络（建议 Wi-Fi）后重新进入通话页再试 |
| 蓝牙耳机没声音 | 会话默认 `defaultToSpeaker` 外放；在控制中心把音频输出切到耳机，或断开重连蓝牙 |
| 每句都提示「已切换本地语音」 | 云端连续失败进入 30 秒冷却；排查 Key/网络后**切一次路由**可立即重试云端 |
| 提示「通话被来电或其他应用打断」 | 通话中来了电话/闹钟/Siri，音频被系统接管：处理完重新点「开始通话」即可（旧版本这里可能直接闪退） |
| 提示「音频设备切换后收音未能恢复」 | 耳机/蓝牙插拔瞬间收音切换失败：重新开始通话；一般情况会自动跟随新路由无缝重启 |
| 提示「语音识别已中断」 | 识别流内部失败（多为断网）：恢复网络后重新开始通话（旧版本这里会静默断麦，界面还在「听」却永远没反应） |
| 通话中开对比模式会闪退/掉麦 | 已修复：通话进行中对比页不再改音频会话类别；若仍有问题请把崩溃日志（设置 → 隐私与安全性 → 分析与改进 → 分析数据里的 FenShen 条目）发出来 |
| 通话一启动就闪退 / 卡死（2026-11-20 已修复） | 两个根因：① iOS 26 `AnalyzerInput` 只收 16bit 整型 PCM，麦克风原生 float32 直接喂是不可捕获的硬 trap——现 tap 直接要 int16 格式 + 规整器兜底；② iOS 27.3 beta 的异步激活 API 完成回调不触发，启动任务永久挂起、之后每次重拨都卡死——现改为后台线程同步激活（必然返回）。若仍复现请附崩溃日志（同上路径） |
| 控制台报 `Model not available for LiveTranscription zh_CN 48,000`（已修复） | 模型按采样率查找：48kHz 输入没有对应模型（zh_CN 模型为 16kHz）。现启动时用 `SpeechAnalyzer.bestAvailableAudioFormat` 协商格式，规整器重采样后再喂；同时补上「模型下载中（downloading）时等待装完」的流程。若仍报错，多为模型下载失败：换 Wi-Fi 后重新开始通话重试 |
| 对比模式试听：本地没声音 / 云端有杂音（2026-11-20 已修复） | 三个根因：① 通话结束后会话类别残留 `.playAndRecord` + 模式 `.voiceChat`，对比页误判「通话进行中」跳过重配——本地合成器静音、播放引擎在 VoIP 输出处理下出声异常，现通话结束即复位为 `.playback`；② 播放节点连接格式与调度 buffer 不一致（int16 被按 float32 解释）→ 云端杂音，现统一 float32@24kHz；③ 通话中打开对比页时改为复用通话的播放器（同一引擎）。诊断看控制台 `[Compare] 试听会话就绪：…`（类别应为 playback、模式 spokenAudio） |
| 多轮对话不可用（第一轮后可再说话没反应，2026-11-20 已修复） | `SpeechTranscriber` 按句段产出结果（volatile 多次重发 + `isFinal` 定稿，文本是该句段自己的、不是全场累计）。旧实现按累计文本做前缀差分，第二段起被丢弃/截错 → 现按 `isFinal` 直接分发。诊断看控制台 `[Call] 识别定稿：…`（每句话应打印一次）与 `[Call] 轮次开始：…` |
| 聊天页气泡里出现「［日期 时间］」前缀（2026-11-20 已修复） | 时间戳前缀只给模型感知时间用（进记忆窗口），不该显示在气泡里。现历史恢复时用 `TimeContext.stripStamp` 去掉前缀再渲染；记忆窗口仍保留完整带戳文本 |

## 9. 文件结构（Sources/Call/）

| 文件 | 职责 |
| --- | --- |
| [CallCore.swift](Sources/Call/CallCore.swift) | 路由开关 `TTSRoute` / 状态机 `CallPhase` / 流式切句 `SentenceSplitter` / 延迟埋点与落盘 `CallMetricsStore` |
| [CallViewModel.swift](Sources/Call/CallViewModel.swift) | 通话核心：一轮对话编排、双路径选择、开口打断、30 秒降级冷却、指标上报 |
| [Protocols.swift](Sources/Call/Protocols.swift) | 五大组件协议抽象：LLMClient / 本地 TTS / 云端流式 TTS / 播放器 / 识别会话（可独立替换、单测用 Mock） |
| [TTSEngines.swift](Sources/Call/TTSEngines.swift) | 路径 A：`AVSpeechSynthesizer` 本地合成（音色缓存）；路径 B：DeepSeek TTS 流式客户端（delegate 分块直出、16bit 采样对齐、断流校验、句间连接池复用） |
| [SpeechSessionImpls.swift](Sources/Call/SpeechSessionImpls.swift) | 语音识别：iOS 26+ 用 SpeechAnalyzer/SpeechTranscriber，低版本回退 SFSpeechRecognizer；含环境事件策略 `AudioEnvironmentPolicy`、系统通知监听 `AudioEnvironmentWatcher`、麦克风格式校验与 tap 缓冲区规整器 `TapBufferConditioner`（通话中闪退加固） |
| [StreamingAudioPlayer.swift](Sources/Call/StreamingAudioPlayer.swift) | 云端 PCM 分片顺序播放（actor，播放图固定 48kHz/float32/单声道）；`stopAll` 丢队列是打断的关键路径 |
| [LLMClients.swift](Sources/Call/LLMClients.swift) | 把现有 Pipeline（人设 + 记忆 + 工具）适配成流式 `LLMClient`，通话与打字共用大脑 |
| [KeychainStore.swift](Sources/Call/KeychainStore.swift) | API Key 的 Keychain 存取（读/写/删，service `local.fenshen`） |

入口与界面在 `Sources/UI/`：[ChatView.swift](Sources/UI/ChatView.swift)（📞 入口）、[PhoneView.swift](Sources/UI/PhoneView.swift)（通话页）。
