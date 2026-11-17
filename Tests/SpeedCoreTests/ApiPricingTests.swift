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

    func testTerraOfficialStandardFastAndLongContextPricing() throws {
        let request = try XCTUnwrap(ApiRequestUsage(usage()))
        let standard = ApiPriceCatalog.estimate(model: "gpt-6.1-terra", usage: request, serviceTier: .standard)
        XCTAssertEqual(standard.uncachedInputUSD, 0.03, accuracy: 1e-12)
        XCTAssertEqual(standard.cachedInputUSD, 0.003, accuracy: 1e-12)
        XCTAssertEqual(standard.cacheWriteUSD, 0.0125, accuracy: 1e-12)
        XCTAssertEqual(standard.outputUSD, 0.025, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(standard.totalUSD), 0.0705, accuracy: 1e-12)
        let fast = ApiPriceCatalog.estimate(model: "gpt-6.1-terra", usage: request, serviceTier: .fast)
        XCTAssertEqual(try XCTUnwrap(fast.totalUSD), 0.141, accuracy: 1e-12)
        let long = ApiRequestUsage(input: 272_001, cachedInput: 100_000, cacheWrite: 50_000, output: 1000)
        let longStandard = ApiPriceCatalog.estimate(model: "gpt-6.1-terra", usage: long, serviceTier: .standard)
        XCTAssertEqual(longStandard.longContextRequests, 1)
        XCTAssertEqual(try XCTUnwrap(longStandard.totalUSD), 0.386502, accuracy: 1e-12)
        let longFast = ApiPriceCatalog.estimate(model: "gpt-6.1-terra", usage: long, serviceTier: .fast)
        XCTAssertEqual(try XCTUnwrap(longFast.totalUSD), 0.773004, accuracy: 1e-12)
        XCTAssertNotNil(ApiPriceCatalog.price(for: "gpt-6.1-terra-2026-10-26"))
        XCTAssertNil(ApiPriceCatalog.price(for: "gpt-6.1-terra-fast"))
        XCTAssertNil(ApiPriceCatalog.estimate(model: "gpt-6.1-terra", usage: request, serviceTier: .unknown).totalUSD)
    }

    func testGPT62PricesIncludeModelSpecificCacheRates() throws {
        let request = try XCTUnwrap(ApiRequestUsage(usage()))
        let astra = ApiPriceCatalog.estimate(model: "gpt-6.2-astra", usage: request, serviceTier: .standard)
        XCTAssertEqual(astra.uncachedInputUSD, 0.24, accuracy: 1e-12)
        XCTAssertEqual(astra.cachedInputUSD, 0.024, accuracy: 1e-12)
        XCTAssertEqual(astra.cacheWriteUSD, 0.1, accuracy: 1e-12)
        XCTAssertEqual(astra.outputUSD, 0.2, accuracy: 1e-12)
        let sol = ApiPriceCatalog.estimate(model: "gpt-6.2-sol", usage: request, serviceTier: .fast)
        XCTAssertEqual(try XCTUnwrap(sol.totalUSD), 0.282, accuracy: 1e-12)
    }

    func testGPT62UltrafastUsesOriginalTimestampAcrossPacificPriceCutoff() throws {
        let cutoff = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-01T08:00:00Z"))
        let before = cutoff.addingTimeInterval(-1)
        let model = "gpt-6.2-astra"
        let request = try XCTUnwrap(ApiRequestUsage(usage(300_000, cached: 100_000, writes: 50_000, output: 10_000)))
        let stats = DailyLogStatistics(timeZone: TimeZone(secondsFromGMT: 0)!)
        for (id, timestamp) in [("promo", before), ("list", cutoff)] {
            stats.recordModern(responseID: id, turnID: "turn", timestamp: timestamp, model: "未知模型",
                               usageJSON: usage(300_000, cached: 100_000, writes: 50_000, output: 10_000),
                               outputSeconds: nil, serviceTier: .ultrafast)
        }
        stats.setModel(model, for: "turn")
        let total = try XCTUnwrap(stats.buckets["2027-03-01"]?[model])
        XCTAssertEqual(total.ultrafastRequests, 2)
        XCTAssertEqual(total.apiCost.longContextRequests, 2)
        XCTAssertEqual(try XCTUnwrap(total.apiCost.totalUSD), 36.72, accuracy: 1e-12)

        var sample = ApiCostSample(id: "promo", timestamp: before, model: "未知模型", usage: request, serviceTier: .ultrafast)
        sample.resolveModel(model)
        XCTAssertEqual(try XCTUnwrap(sample.cost.totalUSD), 12.24, accuracy: 1e-12)
        XCTAssertNil(ApiPriceCatalog.estimate(model: model, usage: request, serviceTier: .ultrafast).totalUSD)
        XCTAssertNil(ApiPriceCatalog.estimate(model: "gpt-6.1-terra", usage: request, serviceTier: .ultrafast, at: before).totalUSD)
        XCTAssertEqual(try XCTUnwrap(ApiPriceCatalog.estimate(model: "gpt-6.1-sol", usage: request, serviceTier: .ultrafast).totalUSD), 6.12, accuracy: 1e-12)
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
