import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    var onPin: () -> Void
    let accent = Color(red: 0.27, green: 0.72, blue: 0.65)

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 19, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Speed").font(.system(size: 15, weight: .semibold))
                    Text("\(monitor.showDailyHistory ? "全部本机历史" : "全部活跃聊天") · \(monitor.scopeText)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onPin) {
                    Image(systemName: monitor.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 13)).frame(width: 27, height: 27)
                }.buttonStyle(.plain).help(monitor.pinned ? "收起悬浮侧栏" : "固定为悬浮侧栏")
                Menu {
                    Button("选择日志文件夹…", action: monitor.chooseFolder)
                    Button("在 Finder 中查看日志") { NSWorkspace.shared.open(monitor.folder) }
                    Button("导出最近记录…", action: monitor.exportCSV).disabled(monitor.session == nil)
                    Button("重新扫描") {
                        monitor.refresh(force: true)
                        if monitor.showDailyHistory { monitor.refreshDaily(force: true) }
                    }
                    Button("为什么看不到云端会话…", action: monitor.explainCloudSessions)
                    Divider()
                    Button("退出 Codex Speed") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 25)
                }.menuStyle(.borderlessButton).fixedSize()
            }

            Picker("查看内容", selection: $monitor.showDailyHistory) {
                Text("实时速度").tag(false)
                Text("每日历史").tag(true)
            }.pickerStyle(.segmented)
                .onChange(of: monitor.showDailyHistory) { showing in
                    if showing { monitor.refreshDaily(force: true) }
                }

            if monitor.showDailyHistory {
                DailyHistoryView(monitor: monitor, accent: accent)
            } else {
            VStack(spacing: 10) {
                Toggle("计入子 agent", isOn: $monitor.includeSubagents)
                    .toggleStyle(.switch)
                    .onChange(of: monitor.includeSubagents) { _ in monitor.aggregationChanged() }
                    .help("控制两行速度和 token 合计是否包含子 agent；明细始终可以查看。")
                HStack {
                    Text("当前会话").foregroundStyle(.secondary)
                    Spacer()
                    Picker("当前会话", selection: $monitor.selectedID) {
                        Text("最近活动（自动）").tag("automatic")
                        ForEach(monitor.sessions) { session in
                            Text(session.label).tag(session.id)
                        }
                    }.labelsHidden().frame(maxWidth: 224)
                    .onChange(of: monitor.selectedID) { _ in monitor.selectionChanged() }
                }
            }.font(.system(size: 11))

            VStack(alignment: .leading, spacing: 10) {
                Text("全局速度合计").font(.system(size: 12, weight: .semibold))
                HStack {
                    Label(monitor.status, systemImage: monitor.isLive ? "circle.fill" : "circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(monitor.isLive ? accent : .secondary)
                    Spacer()
                    Text(monitor.metricTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(rateText(monitor.rate))
                        .font(.system(size: 48, weight: .medium, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                    Text("tok/s").font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer()
                }.accessibilityElement(children: .combine)
                Text("当前会话 \(rateText(monitor.currentSpeed.sum)) tok/s")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text("\(monitor.global.activeChats) 个活跃聊天 · \(monitor.global.sampledAgents)/\(monitor.global.activeAgents) 个 agent 会话有速度样本")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(monitor.sampleAge).font(.system(size: 10)).foregroundStyle(.secondary)
                Sparkline(points: monitor.history, color: accent).frame(height: 52)
            }
            .padding(16)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))

            Text("\(monitor.session?.label ?? "所选会话") · \(monitor.scopeText)")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                metricCard("本轮合计输出", value: tokenText(monitor.round?.usage.output ?? 0), suffix: "tok")
                let output = monitor.round?.usage.output ?? 0
                let reasoning = monitor.round?.usage.reasoning ?? 0
                metricCard("其中推理", value: tokenText(reasoning), suffix: "tok")
                    .help(output > 0 ? String(format: "推理占输出 %.1f%%", Double(reasoning) / Double(output) * 100) : "等待统计")
            }
            if let session = monitor.session {
                VStack(alignment: .leading, spacing: 8) {
                    if monitor.includeSubagents {
                        detailRow("本轮主 / 子输出", value: "\(tokenText(monitor.round?.mainUsage.output ?? 0)) / \(tokenText(monitor.round?.childUsage.output ?? 0)) tok")
                    }
                    detailRow("会话累计输出", value: "\(tokenText(monitor.totalUsage.output)) tok")
                    detailRow("会话累计输入", value: "\(tokenText(monitor.totalUsage.input)) tok")
                        .help("累计请求输入，重复发送的上下文也按日志计入；不是上下文窗口大小。")
                    if monitor.includeSubagents {
                        detailRow("累计主 / 子输出", value: "\(tokenText(session.own.totalUsage.output)) / \(tokenText(session.childUsage.output)) tok")
                    }
                    detailRow("活动子 agent", value: "\(session.agents.filter { $0.isActive(at: monitor.now) }.count) 个")
                        .help("最新一轮尚未结束，且最近 5 分钟有日志更新；包括工具等待中的子 agent。")
                    if !monitor.totalsAreComplete {
                        Text(monitor.isLoading ? "正在读取其余日志，合计会继续补全…" : "部分记录缺少累计用量，当前合计可能不完整。")
                            .foregroundStyle(.orange)
                    }
                    if !session.agents.isEmpty {
                        DisclosureGroup("子 agent 明细") {
                            ForEach(session.agents) { agent in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.label).lineLimit(2)
                                    Text("\(agent.isLoading ? "读取中" : agent.isActive(at: monitor.now) ? "本轮速度" : "最近速度") \(rateText(monitor.agentRate(agent))) tok/s")
                                        .monospacedDigit().foregroundStyle(accent)
                                    Text("累计输出 \(tokenText(agent.totalUsage.output)) tok · 输入 \(tokenText(agent.totalUsage.input)) tok")
                                        .foregroundStyle(.secondary)
                                    Text("\(agent.model) · \(agent.isActive(at: monitor.now) ? "运行中" : "暂无活动")")
                                        .foregroundStyle(.secondary)
                                    Text("\(agent.serviceTier.displayName) · 日志设置")
                                        .foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }
                        }
                    }
                }.font(.system(size: 10))
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("统计口径").foregroundStyle(.secondary)
                    Spacer()
                    Picker("统计口径", selection: $monitor.metric) {
                        Text("连续输出（估算）").tag(SpeedMetric.continuousOutput)
                        Text("扣工具（估算）").tag(SpeedMetric.excludingTools)
                        Text("整轮均速").tag(SpeedMetric.wholeTurn)
                    }.labelsHidden().frame(maxWidth: 224)
                        .onChange(of: monitor.metric) { _ in monitor.metricChanged() }
                }
                HStack(alignment: .top) {
                    Text("当前会话").foregroundStyle(.secondary)
                    Spacer()
                    Text(monitor.session?.label ?? "—")
                        .lineLimit(2).truncationMode(.tail)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 224, alignment: .trailing)
                        .help(monitor.session?.label ?? "等待会话")
                }
                detailRow("主 agent 模型", value: monitor.turn?.model ?? monitor.session?.model ?? "—")
                detailRow("主 agent 模式（设置）", value: monitor.session?.own.serviceTier.displayName ?? "—")
                    .help("读取该 agent 最新的 service_tier 设置，priority / fast 表示 Fast；并非服务端实际计费档位确认。缺少记录时显示未知模式。")
                detailRow("首字延迟（估算）", value: monitor.firstVisibleDelayText)
                    .help("本轮开始到首段可见回答的日志起点；不把推理当成可见文字。日志写入后更新，起点未精确到首个字符。")
                if let delay = monitor.turn?.timeToFirstToken {
                    detailRow("首 token 延迟（日志）", value: String(format: "%.2f秒", delay))
                        .help("Codex 在整轮结束时记录的 time_to_first_token；可能是推理输出，与首字延迟不同。")
                }
                detailRow("主轮耗时 / 合计调用", value: monitor.turn.map {
                    "\(durationText($0.duration(at: $0.end ?? (monitor.session?.own.isActive(at: monitor.now) == true ? monitor.now : $0.lastUsageAt ?? monitor.now)))) · \(monitor.round?.calls ?? 0) 次"
                } ?? "—")
                if monitor.metric == .excludingTools {
                    detailRow("主 agent 扣工具 / 剩余", value: monitor.turn.map {
                        "\($0.toolSecondsToSample.map(durationText) ?? "—") / \($0.nonToolSecondsToSample.map(durationText) ?? "—")"
                    } ?? "—")
                }
                if monitor.metric == .continuousOutput {
                    detailRow("主 agent 有效 / 总调用", value: monitor.turn.map {
                        "\($0.continuousOutputCalls) / \($0.calls) 次"
                    } ?? "—")
                    detailRow("主 agent 输出 / 时间", value: monitor.turn.map {
                        "\(tokenText($0.continuousOutputTokens)) tok / \(String(format: "%.1f", $0.continuousOutputSeconds))秒"
                    } ?? "—")
                }
            }.font(.system(size: 11))

            if let session = monitor.session {
                let recent = Array(session.turns.filter { $0.end != nil && $0.hasUsage }.suffix(3).reversed())
                if !recent.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近完成 · \(monitor.scopeText)输出").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(recent) { turn in
                            HStack {
                                Text(turn.end ?? turn.start, style: .time).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(tokenText(session.round(for: turn, includeSubagents: monitor.includeSubagents).usage.output)) tok").monospacedDigit()
                            }.font(.system(size: 11))
                        }
                    }
                }
            }
            if let message = monitor.message ?? monitor.session?.error {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text(monitor.metricExplanation)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                Text("仅本机会话 · 云端未接入")
                Spacer()
                Text("每秒刷新")
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func metricCard(_ title: String, value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                Text(suffix).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct Sparkline: View {
    let points: [SpeedPoint]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            let values = points.map(\.value)
            let maximum = max(values.max() ?? 1, 1) * 1.15
            let minimumTime = points.first?.time.timeIntervalSince1970 ?? 0
            let span = max(1, (points.last?.time.timeIntervalSince1970 ?? 0) - minimumTime)
            ZStack {
                Path { path in
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = geometry.size.height * fraction
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }.stroke(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                if points.count > 1 {
                    Path { path in
                        for (index, point) in points.enumerated() {
                            let x = (point.time.timeIntervalSince1970 - minimumTime) / span * geometry.size.width
                            let y = geometry.size.height * (1 - min(1, max(0, point.value / maximum)))
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else {
                    Text(points.isEmpty ? "等待统计样本" : "等待下一次统计")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.accessibilityLabel("每次有效统计更新时记录的所选口径速度")
    }
}
