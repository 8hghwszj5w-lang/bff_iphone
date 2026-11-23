import SwiftUI

// MARK: - 主动消息设置页
//
// 入口在设置主页（SettingsView 的插件列表里，见 FenShenApp 接线注释）。
// 所有控件直接绑定 app.proactive.store.config（didSet 即持久化）；
// 整个 config 结构变化时 onChange 会叫引擎 applyConfig()（重建定时器、
// 开关联动清理挂起闹铃、请求通知授权），不需要手动保存按钮。

struct ProactiveSettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("开启主动消息", isOn: bind(\.enabled))
                if app.proactive.store.config.enabled {
                    Toggle("闹铃 · 到点主动跟进", isOn: bind(\.alarmEnabled))
                    Toggle("心跳 · 偶尔自己搭话", isOn: bind(\.heartbeatEnabled))
                }
            } header: {
                Text("机制")
            } footer: {
                Text("闹铃：她聊到该稍后跟进的事时会自己设「n 分钟后主动找你」，到点开口闭环。心跳：App 在前台时每隔一段时间掷一次骰子，命中才真的开口（省 token 也防话痨）。")
            }

            if app.proactive.store.config.enabled {
                Section {
                    Stepper("心跳间隔：\(app.proactive.store.config.heartbeatIntervalMinutes) 分钟",
                            value: bind(\.heartbeatIntervalMinutes), in: 5...120, step: 5)
                    HStack {
                        Text("基础概率")
                        Slider(value: bind(\.heartbeatBaseProbability), in: 0...0.5, step: 0.01)
                        Text("\(Int(app.proactive.store.config.heartbeatBaseProbability * 100))%")
                            .monospacedDigit().frame(width: 40)
                    }
                    Stepper("主动间隔冷却：\(app.proactive.store.config.proactiveCooldownMinutes) 分钟",
                            value: bind(\.proactiveCooldownMinutes), in: 15...240, step: 15)
                } header: {
                    Text("心跳")
                } footer: {
                    Text("实际触发概率 = 基础概率 × 情境：距上次聊天越久越想找你（30 分钟爬满）、深夜减半、免打扰和冷却期归零。心跳只在 App 在前台时进行。")
                }

                Section {
                    DatePicker("开始", selection: minuteBinding(\.quietStartMinute), displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: minuteBinding(\.quietEndMinute), displayedComponents: .hourAndMinute)
                } header: {
                    Text("免打扰时段")
                } footer: {
                    Text("时段内心跳概率为 0、到点的闹铃顺延到时段结束后。")
                }

                Section {
                    let followups = app.proactive.store.state.followups
                    if followups.isEmpty {
                        Text("没有挂着的事").foregroundStyle(.secondary)
                    } else {
                        ForEach(followups) { f in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(f.intent).font(.subheadline)
                                    Text("到点 \(f.fireAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("取消") { app.proactive.cancelFollowup(id: f.id) }
                                    .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("挂起的闹铃")
                } footer: {
                    Text("iOS 冻结后台进程：到点时若在后台，先用预约好的通知敲门（正文是她设闹铃时顺手写的那句），你回到 App 后正文才生成进聊天。")
                }
            }
        }
        .navigationTitle("主动消息")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: app.proactive.store.config) {
            app.proactive.applyConfig()
        }
    }

    // MARK: 绑定

    private func bind<T>(_ keyPath: WritableKeyPath<ProactiveConfig, T>) -> Binding<T> {
        Binding<T>(
            get: { app.proactive.store.config[keyPath: keyPath] },
            set: { app.proactive.store.config[keyPath: keyPath] = $0 })
    }

    /// 分钟数 ↔ DatePicker 的 Date（当天零点 + N 分钟）
    private func minuteBinding(_ keyPath: WritableKeyPath<ProactiveConfig, Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                let cal = Calendar.current
                let dayStart = cal.startOfDay(for: Date())
                return cal.date(byAdding: .minute, value: app.proactive.store.config[keyPath: keyPath], to: dayStart) ?? dayStart
            },
            set: { date in
                app.proactive.store.config[keyPath: keyPath] = ProactivePolicy.minuteOfDay(date)
            })
    }
}
