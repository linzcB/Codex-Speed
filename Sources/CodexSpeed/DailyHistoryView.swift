import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

struct DailyHistoryView: View {
    @ObservedObject var monitor: Monitor
    let accent: Color
    @State private var showDates = false

    private var days: [DailyUsage] { monitor.dailyResult?.days ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("计入子 agent", isOn: $monitor.includeSubagents)
                .toggleStyle(.switch)
                .onChange(of: monitor.includeSubagents) { _ in monitor.aggregationChanged() }
                .font(.system(size: 11))
            HStack {
                Text("日期").foregroundStyle(.secondary)
                Picker("统计日期", selection: $monitor.dailySelectedDay) {
                    Text("今天 · \(monitor.todayKey)").tag("today")
                    if monitor.dailySelectedDay != "today", !days.contains(where: { $0.day == monitor.dailySelectedDay }) {
                        Text(monitor.dailySelectedDay).tag(monitor.dailySelectedDay)
                    }
                    ForEach(days.filter { $0.day != monitor.todayKey }) { day in
                        Text(day.day).tag(day.day)
                    }
                }.labelsHidden()
                Button("刷新") { monitor.refreshDaily(force: true) }
                    .disabled(monitor.dailyResult?.isLoading == true)
            }.font(.system(size: 11))
            Text("全部本机聊天 · \(monitor.scopeText) · \(monitor.dailyResult?.timeZoneIdentifier ?? TimeZone.current.identifier)")
                .font(.system(size: 10)).foregroundStyle(.secondary)

            if monitor.dailyResult == nil || monitor.dailyResult?.isLoading == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("读取历史中 · \(monitor.dailyResult?.filesRead ?? 0)/\(monitor.dailyResult?.totalFiles ?? 0) 个日志\n当前数字会继续补全")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let message = monitor.dailyResult?.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
            }

            if !days.isEmpty {
                DisclosureGroup("历史记录 · \(days.count) 天", isExpanded: $showDates) {
                    VStack(spacing: 10) {
                        ForEach(days) { day in
                            Button {
                                monitor.dailySelectedDay = day.day == monitor.todayKey ? "today" : day.day
                                showDates = false
                            } label: {
                                VStack(spacing: 4) {
                                    HStack {
                                        Text(day.day)
                                        Spacer()
                                        Text("输出 \(tokenText(day.totals.outputTokens)) tok")
                                    }
                                    HStack {
                                        Text("输入 \(tokenText(day.totals.inputTokens)) tok")
                                        Spacer()
                                        Text("均速 \(rateText(day.totals.averageSpeed)) tok/s")
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                    HStack {
                                        Text("API 估算（USD）")
                                        Spacer()
                                        Text("\(money(day.totals.apiCost.totalUSD))\(day.totals.apiCost.pricedRequests < day.totals.requests ? " · 部分" : "")")
                                    }.font(.system(size: 10)).foregroundStyle(accent)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 10)
                }.font(.system(size: 11))
            }

            if let day = monitor.selectedDailyUsage {
                summary(day.totals)
                costSummary(day.totals)
                Divider()
                Text("使用模型 · \(day.models.count) 种")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(day.models) { model in
                    modelRow(model)
                }
            } else if monitor.dailyResult?.isLoading == false {
                Text("这一天暂无已记录的模型调用")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
            }

            Text("按调用用量记录的日期归日，含已结束与已归档聊天。缓存命中率 = 已命中输入 ÷ 有缓存记录的输入；命中 token 已包含在输入总量中。平均速度 = 有效输出 token ÷ 对应输出时间，排除输出前等待和工具执行，含推理。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            Text("历史由本机日志重建，不上传，也不额外保存聊天内容。")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func summary(_ totals: DailyTotals) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                tokenCard("输入 token", value: totals.inputTokens)
                tokenCard("输出 token", value: totals.outputTokens)
            }
            row("其中推理", value: "\(tokenText(totals.reasoningTokens)) tok")
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("缓存命中率")
                    Spacer()
                    Text(percent(totals.cacheHitRate)).foregroundStyle(accent).monospacedDigit()
                }.font(.system(size: 12, weight: .medium))
                if let ratio = totals.cacheHitRate {
                    ProgressView(value: min(1, max(0, ratio))).tint(accent)
                }
                Text("命中 \(tokenText(totals.cachedInputTokens)) / 已知输入 \(tokenText(totals.cacheKnownInputTokens)) tok")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("缓存记录覆盖 \(totals.cacheKnownRequests)/\(totals.requests) 次调用")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("平均输出速度").font(.system(size: 11))
                Spacer()
                Text(rateText(totals.averageSpeed)).font(.system(size: 24, weight: .medium, design: .rounded))
                Text("tok/s").font(.system(size: 11)).foregroundStyle(.secondary)
            }.monospacedDigit()
            Text("连续输出估算 · 计时覆盖 \(totals.timedRequests)/\(totals.requests) 次调用")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            row("有效输出 / 输出时间", value: "\(tokenText(totals.timedOutputTokens)) tok / \(durationText(totals.outputSeconds))")
        }.padding(13)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func costSummary(_ totals: DailyTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API 等价费用（估算）").font(.system(size: 12, weight: .semibold))
            HStack(alignment: .firstTextBaseline) {
                Text(money(totals.apiCost.totalUSD))
                    .font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                Text("USD").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if totals.apiCost.pricedRequests < totals.requests {
                    Text("已定价部分").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            row("未缓存输入", value: money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.uncachedInputUSD))
            row("缓存读取 / 写入", value: "\(money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.cachedInputUSD)) / \(money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.cacheWriteUSD))")
            row("输出（含推理）", value: money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.outputUSD))
            Text("估价覆盖 \(totals.apiCost.pricedRequests)/\(totals.requests) 次 · 长上下文 \(totals.apiCost.longContextRequests) 次")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(tierSummary(totals))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if totals.apiCost.pricedRequests < totals.requests {
                Text("\(totals.requests - totals.apiCost.pricedRequests) 次调用缺少已支持模式、公开价格或缓存分项，未计入费用。")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text("按日志中的模式设置估价 · \(ApiPriceCatalog.checkedDate)\nFast 按 Standard ×2，另计长上下文加价。无法确认服务端降级，不代表订阅实际账单。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            DisclosureGroup("价格表 · 美元 / 百万 token") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("顺序：输入 / 缓存读取 / 缓存写入 / 输出")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    ForEach(ApiPriceCatalog.prices) { price in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(price.model).font(.system(size: 10, weight: .medium))
                            Text("$\(unitPrice(price.input)) / $\(unitPrice(price.cachedInput)) / $\(unitPrice(price.cacheWrite)) / $\(unitPrice(price.output))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text("单次输入超过 272,000 token：输入和缓存单价 ×2，输出单价 ×1.5。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("上表为 Standard；Fast 的输入、缓存和输出均 ×2。缺少模式或尚未支持的模式不估价。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Link("查看 OpenAI 官方价格", destination: ApiPriceCatalog.sourceURL)
                        .font(.system(size: 10))
                }.padding(.top, 8)
            }.font(.system(size: 10))
        }.padding(13)
            .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 13))
    }

    private func money(_ amount: Double?) -> String {
        guard let amount, amount.isFinite else { return "—" }
        return String(format: amount > 0 && amount < 0.01 ? "$%.4f" : "$%.2f", max(0, amount))
    }
    private func unitPrice(_ amount: Double) -> String { String(format: "%g", amount) }
    private func tierSummary(_ totals: DailyTotals) -> String {
        "Standard \(totals.standardRequests) 次 · Fast \(totals.fastRequests) 次 · 未知/未支持 \(totals.unknownTierRequests) 次"
    }

    private func tokenCard(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(tokenText(value)).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRow(_ model: DailyModelUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.model).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            row("输入 / 输出", value: "\(tokenText(model.totals.inputTokens)) / \(tokenText(model.totals.outputTokens)) tok")
            row("缓存命中", value: "\(percent(model.totals.cacheHitRate)) · \(tokenText(model.totals.cachedInputTokens)) tok")
            row("平均输出速度", value: "\(rateText(model.totals.averageSpeed)) tok/s")
            row("API 估算（USD）", value: model.totals.apiCost.totalUSD.map { money($0) + (model.totals.apiCost.pricedRequests < model.totals.requests ? " · 部分" : "") } ?? "未定价或数据不足")
            Text(tierSummary(model.totals)).font(.system(size: 9)).foregroundStyle(.secondary)
            Text("\(model.totals.requests) 次调用 · 缓存覆盖 \(model.totals.cacheKnownRequests) 次 · 计时覆盖 \(model.totals.timedRequests) 次")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 10))
    }
    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }
}
