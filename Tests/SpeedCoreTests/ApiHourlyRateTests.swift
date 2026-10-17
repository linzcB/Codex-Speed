import XCTest
@testable import SpeedCore

final class ApiHourlyRateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 100_000)
    let unitCost = 0.148 // 20k uncached input + 80k cache reads + 10k output.
    var counts: [String: Any] { ["input_tokens": 100_000, "cached_input_tokens": 80_000,
        "cache_write_input_tokens": 0, "output_tokens": 10_000, "reasoning_output_tokens": 5000] }

    func line(_ type: String, _ payload: [String: Any], ago: Double) -> Data {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
            "timestamp": f.string(from: now.addingTimeInterval(-ago))])
        data.append(10); return data
    }
    func meta(_ id: String, parent: String? = nil) -> Data {
        var p: [String: Any] = ["id": id, "source": "vscode"]
        if let parent { p["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent]]] }
        return line("session_meta", p, ago: 1000)
    }
    func reader(_ id: String = "main") -> SessionLog {
        let log = SessionLog(url: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
        log.prepareRecentCosts(at: now); log.ingest(meta(id)); log.modifiedAt = now
        return log
    }
    func context(_ model: String, turn: String = "t", tier: String = "standard", ago: Double = 100) -> Data {
        line("turn_context", ["turn_id": turn, "model": model, "service_tier": tier], ago: ago)
    }
    func usage(_ id: String, turn: String = "t", ago: Double, json: [String: Any]? = nil) -> Data {
        line("token_usage_record", ["turn_id": turn, "response_id": id, "usage": json ?? counts], ago: ago)
    }
    func request(_ id: String, model: String = "gpt-6.1-sol", tier: String = "standard", ago: Double = 10) -> Data {
        line("event_msg", ["type": "task_started", "turn_id": id], ago: ago + 1)
            + context(model, turn: id, tier: tier, ago: ago + 1) + usage(id, turn: id, ago: ago)
            + line("event_msg", ["type": "task_complete", "turn_id": id], ago: ago - 0.1)
    }
    func rate(_ log: SessionLog, window: ApiCostWindow = .fiveMinutes, at date: Date? = nil) -> ApiHourlyRate {
        ApiHourlyRate(sessions: [SessionSnapshot(log: log)], at: date ?? now, window: window)
    }

    func testWallClockWindowExtrapolatesEntireRequestCostAndDecaysToZero() throws {
        let log = reader(); log.ingest(request("r", ago: 1))
        XCTAssertFalse(SessionSnapshot(log: log).isActive(at: now)) // Completed calls still cost money.
        XCTAssertEqual(try XCTUnwrap(rate(log).windowUSD), unitCost, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 12, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rate(log, window: .oneMinute).hourlyUSD), unitCost * 60, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rate(log, window: .fifteenMinutes).hourlyUSD), unitCost * 4, accuracy: 1e-12)
        XCTAssertEqual(rate(log, at: now.addingTimeInterval(901)).hourlyUSD, 0)
    }
    func testBoundaryFutureAndOldSamplesDoNotInflateTheWindow() throws {
        let log = reader()
        log.ingest(request("boundary", ago: 300) + request("older", ago: 301)
            + request("included", ago: 299) + request("future", ago: -1))
        XCTAssertEqual(rate(log).requests, 1)
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 12, accuracy: 1e-12)
        XCTAssertEqual(rate(log, window: .fifteenMinutes).requests, 3)
    }
    func testGlobalAndCurrentScopesDeduplicateAgentsAndHonorBothToggles() throws {
        let main = reader(), child = reader("child"), review = reader("review"), other = reader("other")
        main.ingest(request("m")); child.ingest(request("c", tier: "fast"))
        review.ingest(request("r", model: "codex-auto-review")); other.ingest(request("o"))
        var family = SessionSnapshot(log: main)
        family.agents = [AgentSnapshot(log: child), AgentSnapshot(log: review)]
        let all = [family, family, SessionSnapshot(log: other)]
        let global = ApiHourlyRate(sessions: all, at: now, includeAutoReview: false)
        let current = ApiHourlyRate(sessions: [family], at: now, includeAutoReview: false)
        XCTAssertEqual(global.requests, 3); XCTAssertFalse(global.isPartial)
        XCTAssertEqual(try XCTUnwrap(global.hourlyUSD), unitCost * 4 * 12, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(current.hourlyUSD), unitCost * 3 * 12, accuracy: 1e-12)
        let mainOnly = ApiHourlyRate(sessions: all, at: now, includeSubagents: false, includeAutoReview: false)
        XCTAssertEqual(mainOnly.requests, 2)
        XCTAssertEqual(try XCTUnwrap(mainOnly.hourlyUSD), unitCost * 2 * 12, accuracy: 1e-12)
        let included = ApiHourlyRate(sessions: all, at: now)
        XCTAssertEqual(included.requests, 4); XCTAssertEqual(included.cost.pricedRequests, 3)
        XCTAssertTrue(included.isPartial); XCTAssertEqual(included.hourlyUSD, global.hourlyUSD)
    }
    func testUnknownPricingAndMissingCacheDataAreUnpricedRatherThanFree() {
        let log = reader(); log.ingest(request("unknown", model: "new-model"))
        XCTAssertEqual(rate(log).requests, 1); XCTAssertTrue(rate(log).isPartial); XCTAssertNil(rate(log).hourlyUSD)
        log.ingest(request("paid"))
        XCTAssertEqual(rate(log).cost.pricedRequests, 1); XCTAssertEqual(rate(log).requests, 2)
        var missing = counts; missing.removeValue(forKey: "cache_write_input_tokens")
        log.ingest(context("gpt-6.1-sol", turn: "missing") + usage("missing", turn: "missing", ago: 2, json: missing))
        XCTAssertEqual(rate(log).requests, 3); XCTAssertEqual(rate(log).cost.pricedRequests, 1)
        let empty = reader("empty"); XCTAssertEqual(rate(empty).hourlyUSD, 0)
    }
    func testLateModelOnlyResolvesUnknownRequestsAndKeepsFastAttribution() throws {
        let log = reader()
        log.ingest(line("event_msg", ["type": "task_started", "turn_id": "t"], ago: 100)
            + line("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "standard"]], ago: 101)
            + usage("unknown", ago: 90))
        XCTAssertNil(rate(log).hourlyUSD)
        log.ingest(context("gpt-6.1-sol", ago: 89))
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 12, accuracy: 1e-12)
        log.ingest(request("fast", tier: "fast", ago: 10))
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 3 * 12, accuracy: 1e-12)
        log.ingest(context("gpt-6-astra", turn: "t", ago: 1))
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 3 * 12, accuracy: 1e-12)
    }
    func testMixedModelRequestsAndUnknownTiersKeepTheirOwnPricing() throws {
        let log = reader()
        log.ingest(line("event_msg", ["type": "task_started", "turn_id": "t"], ago: 100)
            + context("gpt-6.1-sol", ago: 100) + usage("paid", ago: 90)
            + context("codex-auto-review", ago: 80) + usage("review", ago: 70)
            + context("gpt-6-astra", ago: 60) + usage("astra", ago: 50))
        let filtered = ApiHourlyRate(sessions: [SessionSnapshot(log: log)], at: now, includeAutoReview: false)
        XCTAssertEqual(filtered.requests, 2); XCTAssertFalse(filtered.isPartial)
        XCTAssertEqual(try XCTUnwrap(filtered.hourlyUSD), (unitCost + 0.78) * 12, accuracy: 1e-12)
        XCTAssertEqual(rate(log).requests, 3); XCTAssertTrue(rate(log).isPartial)
        let unknown = reader("unknown-tier")
        unknown.ingest(request("u", tier: "flex"))
        XCTAssertNil(rate(unknown).hourlyUSD); XCTAssertEqual(rate(unknown).requests, 1)
    }
    func testLegacyReplacementAndModernDuplicatesDoNotDoubleCharge() throws {
        let log = reader()
        log.ingest(line("event_msg", ["type": "task_started", "turn_id": "t"], ago: 100) + context("gpt-6.1-sol")
            + line("event_msg", ["type": "token_count", "turn_id": "t", "info": [
                "total_token_usage": counts, "last_token_usage": counts]], ago: 90))
        XCTAssertEqual(rate(log).requests, 1)
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 12, accuracy: 1e-12)
        log.ingest(usage("modern", ago: 89) + usage("modern", ago: 88))
        XCTAssertEqual(rate(log).requests, 1)
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 12, accuracy: 1e-12)
    }
    func testCostsSurviveTurnRetentionAndPruneOutsideFifteenMinutes() throws {
        let log = reader()
        log.ingest(request("very-old", ago: 1000))
        for i in 0..<60 { log.ingest(request("r\(i)", ago: Double(120 - i * 2))) }
        XCTAssertEqual(log.turns.count, 40)
        XCTAssertEqual(rate(log).requests, 60); XCTAssertEqual(log.recentCosts.count, 60)
        log.ingest(usage("r0", turn: "r0", ago: 1))
        XCTAssertEqual(rate(log).requests, 60)
        log.prepareRecentCosts(at: now.addingTimeInterval(1000))
        XCTAssertTrue(log.recentCosts.isEmpty)
    }
    func testLoadingReadGapsAndUndatedUsageDoNotClaimACompleteZeroRate() {
        let log = reader(); log.ingest(request("r"))
        var family = SessionSnapshot(log: log); family.own.isLoading = true
        XCTAssertNil(ApiHourlyRate(sessions: [family], at: now).hourlyUSD)
        family.own.isLoading = false; family.own.hasRecentCostCoverage = false
        let partial = ApiHourlyRate(sessions: [family], at: now)
        XCTAssertTrue(partial.hasReadGaps); XCTAssertNotNil(partial.hourlyUSD)
        family.own.recentCosts = []
        XCTAssertNil(ApiHourlyRate(sessions: [family], at: now).hourlyUSD)
        let undated = reader("undated")
        var record = try! JSONSerialization.data(withJSONObject: ["type": "token_usage_record", "payload": [
            "turn_id": "t", "response_id": "bad-time", "usage": counts]])
        record.append(10); undated.ingest(record)
        XCTAssertNil(rate(undated).hourlyUSD); XCTAssertTrue(rate(undated).hasReadGaps)
    }
    func testUnattributedLegacyChildIsNotReportedAsFreeAndModernOwnershipResolvesIt() throws {
        let log = SessionLog(url: URL(fileURLWithPath: "/tmp/child.jsonl"))
        log.prepareRecentCosts(at: now); log.modifiedAt = now
        let legacy = line("event_msg", ["type": "token_count", "turn_id": "t", "info": [
            "total_token_usage": counts, "last_token_usage": counts]], ago: 80)
        log.ingest(meta("child", parent: "parent")
            + line("event_msg", ["type": "task_started", "turn_id": "t", "turn_attribution": ["parent_turn_id": "root"]], ago: 100)
            + context("gpt-6.1-sol") + legacy)
        XCTAssertTrue(rate(log).hasReadGaps); XCTAssertNil(rate(log).hourlyUSD)
        log.ingest(usage("owned", ago: 79))
        XCTAssertFalse(rate(log).hasReadGaps)
        XCTAssertEqual(try XCTUnwrap(rate(log).hourlyUSD), unitCost * 12, accuracy: 1e-12)
        log.ingest(legacy)
        XCTAssertFalse(rate(log).hasReadGaps); XCTAssertEqual(rate(log).requests, 1)
    }
    func testRecentlyCompletedAndArchivedFamiliesBeyondPickerLimitAreStillIncluded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions"), archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for i in 0..<12 {
            let id = "thread-\(i)"; let folder = i < 10 ? sessions : archive
            let data = meta(id, parent: i == 11 ? "thread-10" : nil) + request(id, ago: 600 + Double(i))
            let path = folder.appendingPathComponent(id + ".jsonl"); try data.write(to: path)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600 - Double(i))], ofItemAtPath: path.path)
        }
        let result = LogScanner(directory: sessions).scan(at: now, force: true)
        XCTAssertEqual(result.sessions.count, 8); XCTAssertEqual(result.costSessions.count, 11)
        XCTAssertFalse(result.sessions.contains { $0.id == "thread-10" })
        let costs = ApiHourlyRate(sessions: result.costSessions, at: now, window: .fifteenMinutes)
        XCTAssertEqual(costs.requests, 12)
        XCTAssertEqual(try XCTUnwrap(costs.hourlyUSD), unitCost * 12 * 4, accuracy: 1e-12)
        XCTAssertEqual(ApiHourlyRate(sessions: result.costSessions, at: now, window: .fifteenMinutes,
            includeSubagents: false).requests, 11)
        XCTAssertEqual(ApiHourlyRate(sessions: result.costSessions, at: now).hourlyUSD, 0)
    }
}
