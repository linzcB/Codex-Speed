import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

struct ApiHourlyRateView: View {
    @ObservedObject var monitor: Monitor
    let accent: Color

    var body: some View {
        let global = monitor.globalCostRate
        let current = monitor.currentCostRate
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("预计每小时 API 费用")).font(.system(size: 12, weight: .semibold))
            Picker(L10n.text("观察窗口"), selection: $monitor.costWindow) {
                ForEach(ApiCostWindow.allCases, id: \.rawValue) { window in
                    Text(L10n.text("%@分钟", window.minutes)).tag(window)
                }
            }.pickerStyle(.segmented)
                .onChange(of: monitor.costWindow) { _ in monitor.costWindowChanged() }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("全局")).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(money(global?.hourlyUSD)).font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                Text("USD/h").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(L10n.text("当前会话：%@ USD/h", money(current?.hourlyUSD)))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
            if !monitor.costScanReady || global?.isLoading == true {
                Text(L10n.text("正在读取费用用量…")).foregroundStyle(.secondary)
            } else if global == nil {
                Text(L10n.text("等待日志")).foregroundStyle(.secondary)
            } else if let global {
                if global.requests > 0 && global.cost.pricedRequests == 0 {
                    Text(L10n.text("未定价或数据不足")).foregroundStyle(.orange)
                } else if global.isPartial {
                    Text(L10n.text("已定价部分")).foregroundStyle(.orange)
                }
                if global.requests == 0 && !global.hasReadGaps {
                    Text(L10n.text("最近 %@ 分钟没有计入的调用", monitor.costWindow.minutes)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("最近 %@ 分钟：%@ · 估价覆盖 %@/%@ 次", monitor.costWindow.minutes,
                        money(global.windowUSD), global.cost.pricedRequests, global.requests)).foregroundStyle(.secondary)
                }
                if let current {
                    Text(L10n.text("当前会话：%@ · 估价覆盖 %@/%@ 次", money(current.windowUSD),
                        current.cost.pricedRequests, current.requests)).foregroundStyle(.secondary)
                }
                if global.hasReadGaps {
                    Text(L10n.text("部分日志不完整，费用速度可能偏低。")).foregroundStyle(.orange)
                }
            }
            Text(L10n.text("按最近 %@ 分钟的已记录花费外推，包含输入、输出、缓存及日志中的 Fast 设置。等待和工具时间也计入窗口。假设后续使用强度相同；API 等价估算，不代表实际账单。", monitor.costWindow.minutes))
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L10n.text("价格快照：%@", ApiPriceCatalog.checkedDate)).foregroundStyle(.secondary)
                Spacer()
                Link(L10n.text("查看 OpenAI 官方价格"), destination: ApiPriceCatalog.sourceURL)
            }.font(.system(size: 9))
        }.font(.system(size: 10)).padding(13)
            .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 13))
    }
    private func money(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value > 0 && value < 0.0001 { return "<$0.0001" }
        return String(format: value > 0 && value < 0.01 ? "$%.4f" : "$%.2f", max(0, value))
    }
}
