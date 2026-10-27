import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

struct PeriodHistoryView: View {
    @ObservedObject var monitor: Monitor
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("API 费用汇总")).font(.system(size: 12, weight: .semibold))
            Picker(L10n.text("统计范围"), selection: $monitor.historyPeriod) {
                Text(L10n.text("最近 30 天")).tag(HistoryPeriod.last30Days)
                Text(L10n.text("本月")).tag(HistoryPeriod.thisMonth)
                Text(L10n.text("上月")).tag(HistoryPeriod.lastMonth)
            }.labelsHidden().pickerStyle(.segmented)
                .onChange(of: monitor.historyPeriod) { _ in monitor.historyPeriodChanged() }
            if let period = monitor.periodUsage {
                Text(L10n.text("%@ 至 %@ · %@ 天", period.startDay, period.endDay, period.dayCount))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(money(period.totalUSD))
                        .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("USD").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if period.isPartial {
                        Text(L10n.text("已记录部分")).foregroundStyle(.orange).font(.system(size: 10))
                    }
                }
                row(L10n.text("日均费用"), value: money(period.dailyAverageUSD))
                row(L10n.text("输入 / 输出"), value: "\(tokenText(period.totals.inputTokens)) / \(tokenText(period.totals.outputTokens)) tok")
                Text(L10n.text("估价覆盖 %@/%@ 次 · 长上下文 %@ 次", period.totals.apiCost.pricedRequests,
                    period.totals.requests, period.totals.apiCost.longContextRequests)).foregroundStyle(.secondary)
                if period.isLoading {
                    Text(L10n.text("历史读取中，金额会继续补全。")).foregroundStyle(.secondary)
                } else if period.hasReadGaps {
                    Text(L10n.text("部分日志不完整，期间费用可能偏低。")).foregroundStyle(.orange)
                }
                if period.totals.apiCost.pricedRequests < period.totals.requests {
                    Text(L10n.text("%@ 次调用缺少已支持模式、公开价格或缓存分项，未计入费用。",
                        period.totals.requests - period.totals.apiCost.pricedRequests))
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if period.totals.requests == 0 && !period.isLoading && !period.hasReadGaps {
                    Text(L10n.text("当前范围内暂无已记录的调用")).foregroundStyle(.secondary)
                }
                if period.excludedAutoReview.requests > 0 {
                    Text(L10n.text("期间已排除 auto review：输入 %@ / 输出 %@ tok · %@ 次调用",
                        tokenText(period.excludedAutoReview.inputTokens), tokenText(period.excludedAutoReview.outputTokens),
                        period.excludedAutoReview.requests)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !period.models.isEmpty {
                    DisclosureGroup(L10n.text("按模型查看费用 · %@ 种", period.models.count)) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(period.models) { model in
                                VStack(alignment: .leading, spacing: 4) {
                                    row(L10n.modelName(model.model), value: money(model.totals.apiCost.totalUSD))
                                    Text(L10n.text("估价覆盖 %@/%@ 次 · 输入 %@ / 输出 %@ tok",
                                        model.totals.apiCost.pricedRequests, model.totals.requests,
                                        tokenText(model.totals.inputTokens), tokenText(model.totals.outputTokens)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.top, 8)
                    }
                }
                Text(L10n.text("日均按范围内的日历天数计算，含无调用日期；今天仅计已记录部分。"))
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.text("等待历史统计")).foregroundStyle(.secondary)
            }
            Text(L10n.text("仅统计本机已记录用量；价格快照：%@，不代表实际账单。", ApiPriceCatalog.checkedDate))
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 10)).padding(13)
            .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 13))
    }
    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
    private func money(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value > 0 && value < 0.0001 { return "<$0.0001" }
        return String(format: value > 0 && value < 0.01 ? "$%.4f" : "$%.2f", max(0, value))
    }
}
