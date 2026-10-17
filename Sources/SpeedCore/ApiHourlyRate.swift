import Foundation

public enum ApiCostWindow: Int, CaseIterable, Sendable {
    case oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900
    public var minutes: Int { rawValue / 60 }
    public static let maximumSeconds = TimeInterval(fifteenMinutes.rawValue)
}

/// Numeric request summary only. No messages, prompts, or tool contents.
public struct ApiCostSample: Sendable {
    public let id: String
    public let timestamp: Date
    public private(set) var model: String
    public let usage: ApiRequestUsage?
    public let serviceTier: ApiServiceTier
    public private(set) var cost: ApiCostTotals

    public init(id: String, timestamp: Date, model: String, usage: ApiRequestUsage?, serviceTier: ApiServiceTier) {
        self.id = id; self.timestamp = timestamp; self.model = model
        self.usage = usage; self.serviceTier = serviceTier
        cost = ApiPriceCatalog.estimate(model: model, usage: usage, serviceTier: serviceTier)
    }
    mutating func resolveModel(_ model: String) {
        self.model = model
        cost = ApiPriceCatalog.estimate(model: model, usage: usage, serviceTier: serviceTier)
    }
}

/// Wall-clock spending pace, independent of the output-speed metric. Completed
/// calls remain in the window; idle/tool time remains in the denominator.
public struct ApiHourlyRate: Sendable {
    public let window: ApiCostWindow
    public private(set) var requests = 0
    public private(set) var cost = ApiCostTotals()
    public private(set) var isLoading = false
    public private(set) var hasReadGaps = false
    public private(set) var latestSampleAt: Date?
    public var isPartial: Bool { hasReadGaps || cost.pricedRequests < requests }
    public var hourlyUSD: Double? {
        guard !isLoading else { return nil }
        if requests == 0 { return hasReadGaps ? nil : 0 }
        return cost.totalUSD.map { $0 * 3600 / Double(window.rawValue) }
    }
    public var windowUSD: Double? {
        requests == 0 && !hasReadGaps && !isLoading ? 0 : cost.totalUSD
    }

    public init(sessions: [SessionSnapshot], at now: Date, window: ApiCostWindow = .fiveMinutes,
                includeSubagents: Bool = true, includeAutoReview: Bool = true, hasReadGaps: Bool = false) {
        self.window = window; self.hasReadGaps = hasReadGaps
        let begin = now.addingTimeInterval(-Double(window.rawValue))
        var seen = Set<String>()
        for session in sessions {
            for agent in includeSubagents ? session.participants : [session.own] where seen.insert(agent.id).inserted {
                let samples = agent.recentCosts.filter {
                    $0.timestamp.timeIntervalSince1970.isFinite && $0.timestamp > begin && $0.timestamp <= now
                }
                // Older idle files do not make the recent window incomplete.
                if agent.modifiedAt > begin || !samples.isEmpty {
                    isLoading = isLoading || agent.isLoading
                    self.hasReadGaps = self.hasReadGaps || !agent.hasRecentCostCoverage
                }
                for sample in samples where includeAutoReview || !UsageFilter.isAutoReview(model: sample.model) {
                    requests += 1; cost.add(sample.cost)
                    latestSampleAt = max(latestSampleAt ?? sample.timestamp, sample.timestamp)
                }
            }
        }
    }
}
