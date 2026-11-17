import Foundation

public enum ApiServiceTier: String, Sendable {
    case standard, fast, ultrafast, unknown

    public init(recordedValue: String?) {
        switch recordedValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "default", "standard": self = .standard
        case "fast", "priority": self = .fast
        case "ultrafast": self = .ultrafast
        default: self = .unknown
        }
    }
    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .fast: return "Fast"
        case .ultrafast: return "Ultrafast"
        case .unknown: return L10n.text("未知模式")
        }
    }
}

/// Published Standard text-token rates, USD per million tokens.
/// A dated price snapshot is used to estimate API-equivalent usage, not bills.
public struct ApiModelPrice: Identifiable, Sendable {
    public var model: String
    public var input: Double
    public var cachedInput: Double
    public var cacheWrite: Double
    public var output: Double
    public var id: String { model }
}

public struct ApiRequestUsage: Sendable, Equatable {
    public var input: Int
    public var cachedInput: Int
    public var cacheWrite: Int
    public var output: Int

    public init(input: Int, cachedInput: Int, cacheWrite: Int, output: Int) {
        self.input = input; self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite; self.output = output
    }
    init?(_ json: [String: Any]) {
        func count(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            return number.intValue
        }
        guard let input = count(json["input_tokens"]), let output = count(json["output_tokens"]),
              let cached = count(json["cached_input_tokens"] ?? json["input_cached_tokens"]),
              let writes = count(json["cache_write_input_tokens"]),
              cached <= input, writes <= input - cached else { return nil }
        self.init(input: input, cachedInput: cached, cacheWrite: writes, output: output)
    }
}

public struct ApiCostTotals: Sendable, Equatable {
    public var pricedRequests = 0
    public var longContextRequests = 0
    public var uncachedInputUSD: Double = 0
    public var cachedInputUSD: Double = 0
    public var cacheWriteUSD: Double = 0
    public var outputUSD: Double = 0
    public var totalUSD: Double? {
        pricedRequests > 0 ? uncachedInputUSD + cachedInputUSD + cacheWriteUSD + outputUSD : nil
    }
    public init() {}
    mutating func add(_ other: ApiCostTotals, sign: Int = 1) {
        pricedRequests += sign * other.pricedRequests
        longContextRequests += sign * other.longContextRequests
        uncachedInputUSD += Double(sign) * other.uncachedInputUSD
        cachedInputUSD += Double(sign) * other.cachedInputUSD
        cacheWriteUSD += Double(sign) * other.cacheWriteUSD
        outputUSD += Double(sign) * other.outputUSD
        if pricedRequests == 0 { self = ApiCostTotals() }
    }
}

public enum ApiPriceCatalog {
    public static let checkedDate = "2026-11-18"
    public static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing")!
    public static let longContextThreshold = 272_000
    // March 1, 2027 at midnight Pacific Standard Time.
    private static let gpt62UltrafastListRateStart = Date(timeIntervalSince1970: 1_803_888_000)
    public static let prices: [ApiModelPrice] = [
        ApiModelPrice(model: "gpt-6.2-astra", input: 8, cachedInput: 0.4, cacheWrite: 10, output: 40),
        ApiModelPrice(model: "gpt-6.2-sol", input: 2, cachedInput: 0.1, cacheWrite: 2.5, output: 10),
        ApiModelPrice(model: "gpt-6-astra", input: 10, cachedInput: 1, cacheWrite: 12.5, output: 50),
        ApiModelPrice(model: "gpt-6.1-sol", input: 2, cachedInput: 0.1, cacheWrite: 2.5, output: 10),
        ApiModelPrice(model: "gpt-6.1-terra", input: 1, cachedInput: 0.05, cacheWrite: 1.25, output: 5),
        ApiModelPrice(model: "gpt-6-sol", input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 10),
        ApiModelPrice(model: "gpt-6-luna", input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5)
    ]

    public static func price(for model: String) -> ApiModelPrice? {
        prices.first { price in
            if model == price.model { return true }
            guard model.hasPrefix(price.model + "-") else { return false }
            let suffix = String(model.dropFirst(price.model.count + 1))
            return suffix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        }
    }

    private static func multiplier(for tier: ApiServiceTier, model: String, at timestamp: Date?) -> Double? {
        switch tier {
        case .standard: return 1
        case .fast: return 2
        case .unknown: return nil
        case .ultrafast:
            switch model {
            case "gpt-6.2-astra", "gpt-6.2-sol":
                guard let timestamp, timestamp.timeIntervalSince1970.isFinite else { return nil }
                return timestamp < gpt62UltrafastListRateStart ? 3 : 6
            case "gpt-6-astra", "gpt-6.1-sol": return 6
            default: return nil
            }
        }
    }

    public static func estimate(model: String, usage: ApiRequestUsage?, serviceTier: ApiServiceTier,
                                at timestamp: Date? = nil) -> ApiCostTotals {
        guard let usage, let price = price(for: model),
              let tierMultiplier = multiplier(for: serviceTier, model: price.model, at: timestamp),
              usage.input >= 0, usage.output >= 0, usage.cachedInput >= 0, usage.cacheWrite >= 0,
              usage.cachedInput <= usage.input, usage.cacheWrite <= usage.input - usage.cachedInput else {
            return ApiCostTotals()
        }
        let isLong = usage.input > longContextThreshold
        let inputMultiplier: Double = (isLong ? 2 : 1) * tierMultiplier
        let outputMultiplier: Double = (isLong ? 1.5 : 1) * tierMultiplier
        let million = 1_000_000.0
        var cost = ApiCostTotals()
        cost.pricedRequests = 1; cost.longContextRequests = isLong ? 1 : 0
        // Cache reads and writes are disjoint input categories, not surcharges.
        cost.uncachedInputUSD = Double(usage.input - usage.cachedInput - usage.cacheWrite) / million * price.input * inputMultiplier
        cost.cachedInputUSD = Double(usage.cachedInput) / million * price.cachedInput * inputMultiplier
        cost.cacheWriteUSD = Double(usage.cacheWrite) / million * price.cacheWrite * inputMultiplier
        // Reasoning tokens are already included in output_tokens.
        cost.outputUSD = Double(usage.output) / million * price.output * outputMultiplier
        return cost
    }
}
