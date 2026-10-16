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
            Toggle(L10n.text("计入子 agent"), isOn: $monitor.includeSubagents)
                .toggleStyle(.switch)
                .onChange(of: monitor.includeSubagents) { _ in monitor.aggregationChanged() }
                .font(.system(size: 11))
            Toggle(L10n.text("计入 Codex auto review"), isOn: $monitor.includeAutoReview)
                .toggleStyle(.switch)
                .onChange(of: monitor.includeAutoReview) { _ in monitor.autoReviewChanged() }
                .font(.system(size: 11))
                .help(L10n.text("关闭后，从实时速度、会话合计、每日统计和导出中排除 Codex auto review；明细保留。"))
            HStack {
                Text(L10n.text("日期")).foregroundStyle(.secondary)
                Picker(L10n.text("统计日期"), selection: $monitor.dailySelectedDay) {
                    Text(L10n.text("今天 · %@", monitor.todayKey)).tag("today")
                    if monitor.dailySelectedDay != "today", !days.contains(where: { $0.day == monitor.dailySelectedDay }) {
                        Text(monitor.dailySelectedDay).tag(monitor.dailySelectedDay)
                    }
                    ForEach(days.filter { $0.day != monitor.todayKey }) { day in
                        Text(day.day).tag(day.day)
                    }
                }.labelsHidden()
                Button(L10n.text("刷新")) { monitor.refreshDaily(force: true) }
                    .disabled(monitor.dailyResult?.isLoading == true)
            }.font(.system(size: 11))
            Text(L10n.text("全部本机聊天 · %@ · %@", monitor.scopeText, monitor.dailyResult?.timeZoneIdentifier ?? TimeZone.current.identifier))
                .font(.system(size: 10)).foregroundStyle(.secondary)

            if monitor.dailyResult == nil || monitor.dailyResult?.isLoading == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("读取历史中 · %@/%@ 个日志\n当前数字会继续补全", monitor.dailyResult?.filesRead ?? 0, monitor.dailyResult?.totalFiles ?? 0))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let message = monitor.dailyResult?.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !days.isEmpty {
                DisclosureGroup(L10n.text("历史记录 · %@ 天", days.count), isExpanded: $showDates) {
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
                                        Text(L10n.text("输出 %@ tok", tokenText(day.totals.outputTokens)))
                                    }
                                    HStack {
                                        Text(L10n.text("输入 %@ tok", tokenText(day.totals.inputTokens)))
                                        Spacer()
                                        Text(L10n.text("均速 %@ tok/s", rateText(day.totals.averageSpeed)))
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                    HStack {
                                        Text(L10n.text("API 估算（USD）"))
                                        Spacer()
                                        Text("\(money(day.totals.apiCost.totalUSD))\(day.totals.apiCost.pricedRequests < day.totals.requests ? L10n.text(" · 部分") : "")")
                                    }.font(.system(size: 10)).foregroundStyle(accent)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 10)
                }.font(.system(size: 11))
            }

            if let day = monitor.selectedDailyUsage {
                if day.excludedAutoReview.requests > 0 {
                    Text(L10n.text("已排除 auto review：输入 %@ / 输出 %@ tok · %@ 次调用", tokenText(day.excludedAutoReview.inputTokens), tokenText(day.excludedAutoReview.outputTokens), day.excludedAutoReview.requests))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                summary(day.totals)
                if day.totals.requests > 0 {
                    costSummary(day.totals)
                    Divider()
                    Text(L10n.text("使用模型 · %@ 种", day.models.count))
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(day.models) { model in modelRow(model) }
                } else {
                    Text(L10n.text("当前筛选下没有计入的调用"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if monitor.dailyResult?.isLoading == false {
                Text(L10n.text("这一天暂无已记录的模型调用"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
            }

            Text(L10n.text("按调用用量记录的日期归日，含已结束与已归档聊天。缓存命中率 = 已命中输入 ÷ 有缓存记录的输入；命中 token 已包含在输入总量中。平均速度 = 有效输出 token ÷ 对应输出时间，排除输出前等待和工具执行，含推理。"))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("历史由本机日志重建，不上传，也不额外保存聊天内容。"))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func summary(_ totals: DailyTotals) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                tokenCard(L10n.text("输入 token"), value: totals.inputTokens)
                tokenCard(L10n.text("输出 token"), value: totals.outputTokens)
            }
            row(L10n.text("其中推理"), value: "\(tokenText(totals.reasoningTokens)) tok")
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L10n.text("缓存命中率"))
                    Spacer()
                    Text(percent(totals.cacheHitRate)).foregroundStyle(accent).monospacedDigit()
                }.font(.system(size: 12, weight: .medium))
                if let ratio = totals.cacheHitRate {
                    ProgressView(value: min(1, max(0, ratio))).tint(accent)
                }
                Text(L10n.text("命中 %@ / 已知输入 %@ tok", tokenText(totals.cachedInputTokens), tokenText(totals.cacheKnownInputTokens)))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(L10n.text("缓存记录覆盖 %@/%@ 次调用", totals.cacheKnownRequests, totals.requests))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("平均输出速度")).font(.system(size: 11))
                Spacer()
                Text(rateText(totals.averageSpeed)).font(.system(size: 24, weight: .medium, design: .rounded))
                Text("tok/s").font(.system(size: 11)).foregroundStyle(.secondary)
            }.monospacedDigit()
            Text(L10n.text("连续输出估算 · 计时覆盖 %@/%@ 次调用", totals.timedRequests, totals.requests))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            row(L10n.text("有效输出 / 输出时间"), value: "\(tokenText(totals.timedOutputTokens)) tok / \(durationText(totals.outputSeconds))")
        }.padding(13)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func costSummary(_ totals: DailyTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("API 等价费用（估算）")).font(.system(size: 12, weight: .semibold))
            HStack(alignment: .firstTextBaseline) {
                Text(money(totals.apiCost.totalUSD))
                    .font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                Text("USD").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if totals.apiCost.pricedRequests < totals.requests {
                    Text(L10n.text("已定价部分")).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            row(L10n.text("未缓存输入"), value: money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.uncachedInputUSD))
            row(L10n.text("缓存读取 / 写入"), value: "\(money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.cachedInputUSD)) / \(money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.cacheWriteUSD))")
            row(L10n.text("输出（含推理）"), value: money(totals.apiCost.totalUSD == nil ? nil : totals.apiCost.outputUSD))
            Text(L10n.text("估价覆盖 %@/%@ 次 · 长上下文 %@ 次", totals.apiCost.pricedRequests, totals.requests, totals.apiCost.longContextRequests))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(tierSummary(totals))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if totals.apiCost.pricedRequests < totals.requests {
                Text(L10n.text("%@ 次调用缺少已支持模式、公开价格或缓存分项，未计入费用。", totals.requests - totals.apiCost.pricedRequests))
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text("按日志中的模式设置估价 · %@\nFast 按 Standard ×2，另计长上下文加价。无法确认服务端降级，不代表订阅实际账单。", ApiPriceCatalog.checkedDate))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L10n.text("价格表 · 美元 / 百万 token")) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("顺序：输入 / 缓存读取 / 缓存写入 / 输出"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    ForEach(ApiPriceCatalog.prices) { price in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(price.model).font(.system(size: 10, weight: .medium))
                            Text("$\(unitPrice(price.input)) / $\(unitPrice(price.cachedInput)) / $\(unitPrice(price.cacheWrite)) / $\(unitPrice(price.output))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(L10n.text("单次输入超过 272,000 token：输入和缓存单价 ×2，输出单价 ×1.5。"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("上表为 Standard；Fast 的输入、缓存和输出均 ×2。缺少模式或尚未支持的模式不估价。"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(L10n.text("查看 OpenAI 官方价格"), destination: ApiPriceCatalog.sourceURL)
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
        L10n.text("Standard %@ 次 · Fast %@ 次 · 未知/未支持 %@ 次", totals.standardRequests, totals.fastRequests, totals.unknownTierRequests)
    }

    private func tokenCard(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(tokenText(value)).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRow(_ model: DailyModelUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.modelName(model.model)).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            row(L10n.text("输入 / 输出"), value: "\(tokenText(model.totals.inputTokens)) / \(tokenText(model.totals.outputTokens)) tok")
            row(L10n.text("缓存命中"), value: "\(percent(model.totals.cacheHitRate)) · \(tokenText(model.totals.cachedInputTokens)) tok")
            row(L10n.text("平均输出速度"), value: "\(rateText(model.totals.averageSpeed)) tok/s")
            row(L10n.text("API 估算（USD）"), value: model.totals.apiCost.totalUSD.map { money($0) + (model.totals.apiCost.pricedRequests < model.totals.requests ? L10n.text(" · 部分") : "") } ?? L10n.text("未定价或数据不足"))
            Text(tierSummary(model.totals)).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(L10n.text("%@ 次调用 · 缓存覆盖 %@ 次 · 计时覆盖 %@ 次", model.totals.requests, model.totals.cacheKnownRequests, model.totals.timedRequests))
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
