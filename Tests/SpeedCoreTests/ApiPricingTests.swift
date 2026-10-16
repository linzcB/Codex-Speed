import XCTest
@testable import SpeedCore

final class ApiPricingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1000)
    private func usage(_ input: Int = 100_000, cached: Int = 60_000, writes: Int = 10_000, output: Int = 5_000) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": writes,
         "output_tokens": output, "reasoning_output_tokens": output / 2]
    }

    func testCacheReadsWritesAreInputPartitionsAndReasoningNotChargedTwice() throws {
        let value = ApiPriceCatalog.estimate(model: "gpt-6-astra", usage: ApiRequestUsage(usage()), serviceTier: .standard)
        XCTAssertEqual(value.pricedRequests, 1)
        XCTAssertEqual(value.uncachedInputUSD, 0.3, accuracy: 1e-12)
        XCTAssertEqual(value.cachedInputUSD, 0.06, accuracy: 1e-12)
        XCTAssertEqual(value.cacheWriteUSD, 0.125, accuracy: 1e-12)
        XCTAssertEqual(value.outputUSD, 0.25, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(value.totalUSD), 0.735, accuracy: 1e-12)
    }

    func testSolVersionsHaveDifferentCachedInputRates() throws {
        let request = ApiRequestUsage(input: 100_000, cachedInput: 90_000, cacheWrite: 0, output: 10_000)
        XCTAssertEqual(try XCTUnwrap(ApiPriceCatalog.estimate(model: "gpt-6.1-sol", usage: request, serviceTier: .standard).totalUSD), 0.129, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ApiPriceCatalog.estimate(model: "gpt-6-sol", usage: request, serviceTier: .standard).totalUSD), 0.138, accuracy: 1e-12)
    }

    func testLongContextThresholdAppliesToEntireRequestAndAllPriceCategories() throws {
        let boundary = ApiRequestUsage(input: 272_000, cachedInput: 0, cacheWrite: 0, output: 1000)
        let short = ApiPriceCatalog.estimate(model: "gpt-6.1-sol", usage: boundary, serviceTier: .standard)
        XCTAssertEqual(short.longContextRequests, 0)
        XCTAssertEqual(try XCTUnwrap(short.totalUSD), 0.554, accuracy: 1e-12)
        let over = ApiPriceCatalog.estimate(model: "gpt-6.1-sol", usage: ApiRequestUsage(input: 272_001, cachedInput: 100_000, cacheWrite: 50_000, output: 1000), serviceTier: .standard)
        XCTAssertEqual(over.longContextRequests, 1)
        XCTAssertEqual(over.uncachedInputUSD, 122_001.0 / 1_000_000 * 4, accuracy: 1e-12)
        XCTAssertEqual(over.cachedInputUSD, 0.02, accuracy: 1e-12)
        XCTAssertEqual(over.cacheWriteUSD, 0.25, accuracy: 1e-12)
        XCTAssertEqual(over.outputUSD, 0.015, accuracy: 1e-12)
    }

    func testUnknownModelsAndMissingOrInvalidUsageAreUnpricedRatherThanZero() {
        XCTAssertNil(ApiPriceCatalog.estimate(model: "codex-auto-review", usage: ApiRequestUsage(usage()), serviceTier: .standard).totalUSD)
        var missing = usage(); missing.removeValue(forKey: "cached_input_tokens")
        XCTAssertNil(ApiRequestUsage(missing))
        missing = usage(); missing.removeValue(forKey: "cache_write_input_tokens")
        XCTAssertNil(ApiRequestUsage(missing))
        XCTAssertNil(ApiRequestUsage(usage(10, cached: 8, writes: 3)))
        XCTAssertNil(ApiPriceCatalog.estimate(model: "gpt-6-astra", usage: ApiRequestUsage(input: -1, cachedInput: 0, cacheWrite: 0, output: 0), serviceTier: .standard).totalUSD)
        XCTAssertNotNil(ApiPriceCatalog.price(for: "gpt-6.1-sol-2026-09-29"))
        XCTAssertNil(ApiPriceCatalog.price(for: "gpt-6.1-sol-fast"))
    }

    func testDailyCostsUsePerRequestContextThresholdAndDeduplicateResponses() throws {
        let stats = DailyLogStatistics(timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.setModel("gpt-6.1-sol", for: "turn")
        for id in ["r1", "r2", "r2"] {
            stats.recordModern(responseID: id, turnID: "turn", timestamp: date, model: "gpt-6.1-sol",
                usageJSON: usage(200_000, cached: 0, writes: 0, output: 1000), outputSeconds: nil, serviceTier: .standard)
        }
        let total = try XCTUnwrap(stats.buckets.values.first?["gpt-6.1-sol"])
        XCTAssertEqual(total.inputTokens, 400_000)
        XCTAssertEqual(total.apiCost.pricedRequests, 2)
        XCTAssertEqual(total.apiCost.longContextRequests, 0)
        XCTAssertEqual(try XCTUnwrap(total.apiCost.totalUSD), 0.82, accuracy: 1e-12)
    }

    func testLateModelContextRepricesOnlyUnresolvedRequests() throws {
        let stats = DailyLogStatistics(timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.recordModern(responseID: "r1", turnID: "turn", timestamp: date, model: "previous-model", usageJSON: usage(), outputSeconds: nil, serviceTier: .standard)
        XCTAssertNil(stats.buckets.values.first?["未知模型"]?.apiCost.totalUSD)
        stats.setModel("gpt-6-astra", for: "turn")
        XCTAssertEqual(try XCTUnwrap(stats.buckets.values.first?["gpt-6-astra"]?.apiCost.totalUSD), 0.735, accuracy: 1e-12)
        stats.setModel("gpt-6.1-sol", for: "turn")
        stats.recordModern(responseID: "r2", turnID: "turn", timestamp: date, model: "gpt-6.1-sol", usageJSON: usage(), outputSeconds: nil, serviceTier: .standard)
        XCTAssertEqual(stats.buckets.values.first?["gpt-6-astra"]?.apiCost.pricedRequests, 1)
        XCTAssertEqual(stats.buckets.values.first?["gpt-6.1-sol"]?.apiCost.pricedRequests, 1)
    }

    func testModernUsageReplacesProvisionalLegacyCosts() throws {
        let stats = DailyLogStatistics(timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.setModel("gpt-6-astra", for: "turn")
        let counts = usage()
        stats.recordLegacy(turnID: "turn", timestamp: date, model: "gpt-6-astra", totalJSON: counts, lastJSON: counts, serviceTier: .standard)
        XCTAssertEqual(stats.buckets.values.first?["gpt-6-astra"]?.apiCost.pricedRequests, 1)
        stats.recordModern(responseID: "r1", turnID: "turn", timestamp: date, model: "gpt-6-astra", usageJSON: counts, outputSeconds: nil, serviceTier: .standard)
        let total = try XCTUnwrap(stats.buckets.values.first?["gpt-6-astra"])
        XCTAssertEqual(total.requests, 1)
        XCTAssertEqual(total.apiCost.pricedRequests, 1)
        XCTAssertEqual(try XCTUnwrap(total.apiCost.totalUSD), 0.735, accuracy: 1e-12)
    }
}
