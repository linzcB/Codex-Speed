import Foundation

public enum HistoryPeriod: String, CaseIterable, Sendable {
    case last30Days, thisMonth, lastMonth
}

/// Calendar-day rollup of the existing daily ledger. Does not read logs or
/// reprice requests. The same local time zone governs the range and day keys.
public struct PeriodUsage: Sendable {
    public let period: HistoryPeriod
    public let referenceDay: String
    public let startDay: String
    public let endDay: String
    public let interval: DateInterval
    public let days: [DailyUsage]
    public let totals: DailyTotals
    public let models: [DailyModelUsage]
    public let excludedAutoReview: DailyTotals
    public let isLoading: Bool
    public let hasReadGaps: Bool
    public var dayCount: Int { days.count }
    public var isPartial: Bool { isLoading || hasReadGaps || totals.apiCost.pricedRequests < totals.requests }
    public var totalUSD: Double? {
        if totals.requests == 0 { return isLoading || hasReadGaps ? nil : 0 }
        return totals.apiCost.totalUSD
    }
    public var dailyAverageUSD: Double? { totalUSD.map { $0 / Double(dayCount) } }

    public init(result: DailyScanResult, period: HistoryPeriod = .last30Days, at now: Date) {
        self.period = period
        isLoading = result.isLoading; hasReadGaps = result.hasReadGaps
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: result.timeZoneIdentifier) ?? .current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let monthStart = calendar.dateInterval(of: .month, for: today)!.start
        let begin: Date, end: Date
        switch period {
        case .last30Days:
            begin = calendar.date(byAdding: .day, value: -29, to: today)!; end = tomorrow
        case .thisMonth:
            begin = monthStart; end = tomorrow
        case .lastMonth:
            begin = calendar.date(byAdding: .month, value: -1, to: monthStart)!; end = monthStart
        }
        interval = DateInterval(start: begin, end: end)
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        referenceDay = formatter.string(from: today)
        startDay = formatter.string(from: begin)
        endDay = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: end)!)
        let count = calendar.dateComponents([.day], from: begin, to: end).day!
        let source = Dictionary(uniqueKeysWithValues: result.days.map { ($0.day, $0) })
        days = (0..<count).reversed().map { offset in
            let key = formatter.string(from: calendar.date(byAdding: .day, value: offset, to: begin)!)
            return source[key] ?? DailyUsage(day: key, totals: DailyTotals(), models: [])
        }
        var total = DailyTotals(), excluded = DailyTotals()
        var modelTotals: [String: DailyTotals] = [:]
        for day in days {
            total.add(day.totals); excluded.add(day.excludedAutoReview)
            for model in day.models { modelTotals[model.model, default: DailyTotals()].add(model.totals) }
        }
        totals = total; excludedAutoReview = excluded
        models = modelTotals.map { DailyModelUsage(model: $0.key, totals: $0.value) }.sorted { $0.model < $1.model }
    }
}
