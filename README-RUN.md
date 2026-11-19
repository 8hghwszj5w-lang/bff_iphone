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

- **会话配置**（[CallViewModel.swift](Sources/Call/CallViewModel.swift)）：`AVAudioSession` `.playAndRecord` + `mode: .voiceChat` + `[.defaultToSpeaker, .allowBluetooth, .duckOthers]`——录音 + 外放、蓝牙耳机可用、自动压低他人背景音。
- **回声消除**：输入节点 `setVoiceProcessingEnabled(true)` 启用系统级 voice processing，TTS 外放不会被当成你在说话——所以 **speaking 期间识别一直开着**，为打断做准备。
- **打断（barge-in）**：speaking 期间实时字幕比基线多 1 个字 → 立即**取消 LLM 网络流 + 取消 TTS 流 + 清空播放器已入队的音频** → 短暂 `interrupted` 后直接回 `listening` 收音。
- 打断粒度见第 7 节限制：从你开口到她停声，延迟约等于一个识别帧。

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

## 9. 文件结构（Sources/Call/）

| 文件 | 职责 |
| --- | --- |
| [CallCore.swift](Sources/Call/CallCore.swift) | 路由开关 `TTSRoute` / 状态机 `CallPhase` / 流式切句 `SentenceSplitter` / 延迟埋点与落盘 `CallMetricsStore` |
| [CallViewModel.swift](Sources/Call/CallViewModel.swift) | 通话核心：一轮对话编排、双路径选择、开口打断、30 秒降级冷却、指标上报 |
| [Protocols.swift](Sources/Call/Protocols.swift) | 五大组件协议抽象：LLMClient / 本地 TTS / 云端流式 TTS / 播放器 / 识别会话（可独立替换、单测用 Mock） |
| [TTSEngines.swift](Sources/Call/TTSEngines.swift) | 路径 A：`AVSpeechSynthesizer` 本地合成；路径 B：DeepSeek TTS 流式客户端（含断流校验） |
| [SpeechSessionImpls.swift](Sources/Call/SpeechSessionImpls.swift) | 语音识别：iOS 26+ 用 SpeechAnalyzer/SpeechTranscriber，低版本回退 SFSpeechRecognizer；含环境事件策略 `AudioEnvironmentPolicy`、系统通知监听 `AudioEnvironmentWatcher` 与麦克风格式校验（通话中闪退加固） |
| [StreamingAudioPlayer.swift](Sources/Call/StreamingAudioPlayer.swift) | 云端 PCM 分片顺序播放（actor）；`stopAll` 丢队列是打断的关键路径 |
| [LLMClients.swift](Sources/Call/LLMClients.swift) | 把现有 Pipeline（人设 + 记忆 + 工具）适配成流式 `LLMClient`，通话与打字共用大脑 |
| [KeychainStore.swift](Sources/Call/KeychainStore.swift) | API Key 的 Keychain 存取（读/写/删，service `local.fenshen`） |

入口与界面在 `Sources/UI/`：[ChatView.swift](Sources/UI/ChatView.swift)（📞 入口）、[PhoneView.swift](Sources/UI/PhoneView.swift)（通话页）。
