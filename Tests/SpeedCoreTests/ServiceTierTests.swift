import XCTest
@testable import SpeedCore

final class ServiceTierTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1000)
    private var counts: [String: Any] {
        ["input_tokens": 100_000, "cached_input_tokens": 90_000,
         "cache_write_input_tokens": 0, "output_tokens": 10_000]
    }
    private func joined(_ chunks: Data...) -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }
    private func line(_ kind: String, _ payload: [String: Any], at seconds: Double) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try! JSONSerialization.data(withJSONObject: ["type": kind, "payload": payload,
            "timestamp": formatter.string(from: base.addingTimeInterval(seconds))])
        data.append(10); return data
    }
    private func settings(_ mode: Any, at seconds: Double, owner: String = "main") -> Data {
        line("event_msg", ["type": "thread_settings_applied", "thread_id": owner,
            "thread_settings": ["service_tier": mode]], at: seconds)
    }
    private func prefix(id: String = "main", parent: String? = nil) -> Data {
        var metadata: [String: Any] = ["id": id, "source": "vscode"]
        if let parent { metadata["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent]]] }
        return joined(line("session_meta", metadata, at: 0),
            line("event_msg", ["type": "task_started", "turn_id": "turn"], at: 1),
            line("turn_context", ["turn_id": "turn", "model": "gpt-6.1-sol"], at: 1))
    }
    private func output(from start: Double, to end: Double) -> Data {
        line("event_msg", ["type": "item_completed", "turn_id": "turn",
            "item": ["type": "AgentMessage", "id": "output-\(end)"],
            "started_at_ms": base.addingTimeInterval(start).timeIntervalSince1970 * 1000,
            "completed_at_ms": base.addingTimeInterval(end).timeIntervalSince1970 * 1000], at: end)
    }
    private func usage(_ response: String, at seconds: Double, owner: String = "main") -> Data {
        line("token_usage_record", ["thread_id": owner, "turn_id": "turn", "response_id": response,
            "usage": counts], at: seconds)
    }
    private func reader(_ data: Data) -> SessionLog {
        let log = SessionLog(url: URL(fileURLWithPath: "/tmp/synthetic-tier.jsonl"), fullHistory: true,
                             statisticsTimeZone: TimeZone(secondsFromGMT: 0)!)
        log.ingest(data); return log
    }
    private func total(_ log: SessionLog) throws -> DailyTotals {
        try XCTUnwrap(log.dailyStatistics?.buckets.values.first?["gpt-6.1-sol"])
    }

    func testFastAliasesAndUnknownModesDoNotDefaultToStandard() {
        XCTAssertEqual(ApiServiceTier(recordedValue: "priority"), .fast)
        XCTAssertEqual(ApiServiceTier(recordedValue: " Fast "), .fast)
        XCTAssertEqual(ApiServiceTier(recordedValue: "default"), .standard)
        for value in [nil, "auto", "ultrafast", "scale", "future-tier"] {
            XCTAssertEqual(ApiServiceTier(recordedValue: value), .unknown)
            XCTAssertNil(ApiPriceCatalog.estimate(model: "gpt-6.1-sol", usage: ApiRequestUsage(counts),
                                                 serviceTier: ApiServiceTier(recordedValue: value)).totalUSD)
        }
    }
    func testFastMultipliesAllCategoriesAndStacksWithLongContext() throws {
        let usage = ApiRequestUsage(input: 300_000, cachedInput: 100_000, cacheWrite: 50_000, output: 10_000)
        let standard = ApiPriceCatalog.estimate(model: "gpt-6.1-sol", usage: usage, serviceTier: .standard)
        let fast = ApiPriceCatalog.estimate(model: "gpt-6.1-sol", usage: usage, serviceTier: .fast)
        XCTAssertEqual(fast.pricedRequests, 1); XCTAssertEqual(fast.longContextRequests, 1)
        XCTAssertEqual(fast.uncachedInputUSD, 2 * standard.uncachedInputUSD, accuracy: 1e-12)
        XCTAssertEqual(fast.cachedInputUSD, 2 * standard.cachedInputUSD, accuracy: 1e-12)
        XCTAssertEqual(fast.cacheWriteUSD, 2 * standard.cacheWriteUSD, accuracy: 1e-12)
        XCTAssertEqual(fast.outputUSD, 2 * standard.outputUSD, accuracy: 1e-12)
        let standardTotal = try XCTUnwrap(standard.totalUSD)
        XCTAssertEqual(try XCTUnwrap(fast.totalUSD), 2 * standardTotal, accuracy: 1e-12)
    }
    func testMidOutputSettingChangeDoesNotRepriceTheInFlightRequest() throws {
        let data = joined(prefix(), settings("priority", at: 1.5), settings("default", at: 3),
            output(from: 2, to: 4), usage("r1", at: 5),
            output(from: 6, to: 8), usage("r2", at: 9), usage("r2", at: 10))
        let log = reader(data), totals = try total(log)
        XCTAssertEqual(log.serviceTier, .standard)
        XCTAssertEqual(AgentSnapshot(log: log).serviceTier, .standard)
        XCTAssertEqual(totals.fastRequests, 1); XCTAssertEqual(totals.standardRequests, 1)
        XCTAssertEqual(totals.unknownTierRequests, 0); XCTAssertEqual(totals.requests, 2)
        XCTAssertEqual(try XCTUnwrap(totals.apiCost.totalUSD), 0.129 * 3, accuracy: 1e-12)
    }
    func testLaterSettingCannotFillInUnknownHistoricalRequests() throws {
        let log = reader(joined(prefix(), output(from: 2, to: 4), usage("r1", at: 5),
            settings("fast", at: 6), output(from: 7, to: 9), usage("r2", at: 10)))
        let totals = try total(log)
        XCTAssertEqual(totals.unknownTierRequests, 1); XCTAssertEqual(totals.fastRequests, 1)
        XCTAssertEqual(totals.apiCost.pricedRequests, 1)
        XCTAssertEqual(try XCTUnwrap(totals.apiCost.totalUSD), 0.258, accuracy: 1e-12)
    }
    func testNullSettingAndCopiedParentSettingDoNotLeakFastToChild() throws {
        let child = reader(joined(prefix(id: "child", parent: "main"), settings("priority", at: 1.5, owner: "main"),
            output(from: 2, to: 4), usage("r1", at: 5, owner: "child")))
        XCTAssertEqual(child.serviceTier, .unknown)
        XCTAssertNil(try total(child).apiCost.totalUSD)
        let main = reader(joined(prefix(), settings("priority", at: 1.5), settings(NSNull(), at: 2),
            output(from: 3, to: 4), usage("r1", at: 5)))
        XCTAssertEqual(main.serviceTier, .unknown)
        XCTAssertEqual(try total(main).unknownTierRequests, 1)
    }
    func testLateModelBackfillKeepsTheOriginalFastPrice() throws {
        let stats = DailyLogStatistics(timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.recordModern(responseID: "r", turnID: "turn", timestamp: base, model: "unknown",
                           usageJSON: counts, outputSeconds: nil, serviceTier: .fast)
        stats.setModel("gpt-6.1-sol", for: "turn")
        let totals = try XCTUnwrap(stats.buckets.values.first?["gpt-6.1-sol"])
        XCTAssertEqual(totals.fastRequests, 1)
        XCTAssertEqual(try XCTUnwrap(totals.apiCost.totalUSD), 0.258, accuracy: 1e-12)
    }
    func testModernRecordReplacesLegacyTierCounters() throws {
        let stats = DailyLogStatistics(timeZone: TimeZone(secondsFromGMT: 0)!)
        stats.setModel("gpt-6.1-sol", for: "turn")
        stats.recordLegacy(turnID: "turn", timestamp: base, model: "gpt-6.1-sol", totalJSON: counts,
                           lastJSON: counts, serviceTier: .standard)
        stats.recordModern(responseID: "r", turnID: "turn", timestamp: base, model: "gpt-6.1-sol",
                           usageJSON: counts, outputSeconds: nil, serviceTier: .fast)
        let totals = try XCTUnwrap(stats.buckets.values.first?["gpt-6.1-sol"])
        XCTAssertEqual(totals.standardRequests, 0); XCTAssertEqual(totals.fastRequests, 1)
        XCTAssertEqual(totals.requests, 1)
        XCTAssertEqual(try XCTUnwrap(totals.apiCost.totalUSD), 0.258, accuracy: 1e-12)
    }
    func testMainAndChildUseTheirOwnModesAndRespectTheChildSwitch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try joined(prefix(), settings("default", at: 1.5), output(from: 2, to: 4), usage("r1", at: 5))
            .write(to: directory.appendingPathComponent("main.jsonl"))
        try joined(prefix(id: "child", parent: "main"), settings("priority", at: 1.5, owner: "child"),
            output(from: 2, to: 4), usage("r2", at: 5, owner: "child"))
            .write(to: directory.appendingPathComponent("child.jsonl"))
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: TimeZone(secondsFromGMT: 0)!)
        let family = try XCTUnwrap(scanner.scan(force: true).days.first?.totals)
        XCTAssertEqual(family.fastRequests, 1); XCTAssertEqual(family.standardRequests, 1)
        XCTAssertEqual(try XCTUnwrap(family.apiCost.totalUSD), 0.387, accuracy: 1e-12)
        let main = try XCTUnwrap(scanner.scan(includeSubagents: false).days.first?.totals)
        XCTAssertEqual(main.fastRequests, 0); XCTAssertEqual(main.standardRequests, 1)
        XCTAssertEqual(try XCTUnwrap(main.apiCost.totalUSD), 0.129, accuracy: 1e-12)
    }
}
