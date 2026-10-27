import XCTest
@testable import SpeedCore

final class PeriodStatisticsTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func result(_ days: [DailyUsage] = [], zone: String = "Asia/Shanghai",
                        loading: Bool = false, gaps: Bool = false, message: String? = nil) -> DailyScanResult {
        DailyScanResult(days: days, isLoading: loading, filesRead: loading ? 0 : 1,
            totalFiles: 1, message: message, timeZoneIdentifier: zone, hasReadGaps: gaps)
    }
    private func day(_ key: String, model: String = "model-a", cost: Double?) -> DailyUsage {
        var totals = DailyTotals()
        totals.requests = 1; totals.inputTokens = 100; totals.outputTokens = 10
        if let cost { totals.apiCost.pricedRequests = 1; totals.apiCost.outputUSD = cost }
        return DailyUsage(day: key, totals: totals, models: [DailyModelUsage(model: model, totals: totals)])
    }

    func testLast30DaysIncludesTodayAnd29PriorCalendarDays() {
        let source = result([
            day("2026-09-22", cost: 100), day("2026-09-23", cost: 1),
            day("2026-10-01", cost: 2), day("2026-10-22", model: "model-b", cost: 4),
            day("2026-10-23", cost: 100)
        ])
        let value = PeriodUsage(result: source, at: date("2026-10-22T06:00:00Z"))
        XCTAssertEqual(value.startDay, "2026-09-23"); XCTAssertEqual(value.endDay, "2026-10-22")
        XCTAssertEqual(value.dayCount, 30); XCTAssertEqual(value.days.first?.day, "2026-10-22")
        XCTAssertEqual(value.days.last?.day, "2026-09-23")
        XCTAssertEqual(value.totalUSD, 7); XCTAssertEqual(value.dailyAverageUSD!, 7.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(value.totals.inputTokens, 300); XCTAssertEqual(value.totals.outputTokens, 30)
        XCTAssertEqual(value.totals.requests, 3); XCTAssertFalse(value.isPartial)
        XCTAssertEqual(value.models.map(\.model), ["model-a", "model-b"])
        XCTAssertEqual(value.models.map { $0.totals.apiCost.totalUSD }, [3, 4])
        XCTAssertEqual(value.days.filter { $0.totals.requests == 0 }.count, 27)
    }

    func testMonthToDateAndPreviousMonthUseCalendarBoundaries() {
        let source = result([day("2026-08-31", cost: 100), day("2026-09-01", cost: 1),
            day("2026-09-30", cost: 2), day("2026-10-01", cost: 4), day("2026-10-22", cost: 8),
            day("2026-10-23", cost: 100)])
        let now = date("2026-10-22T06:00:00Z")
        let current = PeriodUsage(result: source, period: .thisMonth, at: now)
        XCTAssertEqual(current.startDay, "2026-10-01"); XCTAssertEqual(current.endDay, "2026-10-22")
        XCTAssertEqual(current.dayCount, 22); XCTAssertEqual(current.totalUSD, 12)
        XCTAssertEqual(current.dailyAverageUSD!, 12.0 / 22, accuracy: 1e-12)
        let previous = PeriodUsage(result: source, period: .lastMonth, at: now)
        XCTAssertEqual(previous.startDay, "2026-09-01"); XCTAssertEqual(previous.endDay, "2026-09-30")
        XCTAssertEqual(previous.dayCount, 30); XCTAssertEqual(previous.totalUSD, 3)
    }

    func testYearRolloverAndLeapYearFebruary() {
        let december = PeriodUsage(result: result(), period: .lastMonth, at: date("2026-01-01T06:00:00Z"))
        XCTAssertEqual(december.startDay, "2025-12-01"); XCTAssertEqual(december.endDay, "2025-12-31")
        XCTAssertEqual(december.dayCount, 31)
        let leap = PeriodUsage(result: result(), period: .lastMonth, at: date("2024-03-01T06:00:00Z"))
        XCTAssertEqual(leap.startDay, "2024-02-01"); XCTAssertEqual(leap.endDay, "2024-02-29")
        XCTAssertEqual(leap.dayCount, 29)
        let ordinary = PeriodUsage(result: result(), period: .lastMonth, at: date("2025-03-01T06:00:00Z"))
        XCTAssertEqual(ordinary.endDay, "2025-02-28"); XCTAssertEqual(ordinary.dayCount, 28)
    }

    func testTimeZoneControlsTheReferenceDateAndMonth() {
        let now = date("2026-10-01T00:30:00Z")
        let shanghai = PeriodUsage(result: result(), period: .thisMonth, at: now)
        let pacific = PeriodUsage(result: result(zone: "America/Los_Angeles"), period: .thisMonth, at: now)
        XCTAssertEqual(shanghai.referenceDay, "2026-10-01"); XCTAssertEqual(shanghai.dayCount, 1)
        XCTAssertEqual(pacific.referenceDay, "2026-09-30"); XCTAssertEqual(pacific.startDay, "2026-09-01")
        XCTAssertEqual(pacific.endDay, "2026-09-30"); XCTAssertEqual(pacific.dayCount, 30)
    }

    func testDaylightSavingUsesCalendarDaysRatherThanFixedSeconds() {
        let value = PeriodUsage(result: result(zone: "America/Los_Angeles"), at: date("2026-11-15T12:00:00Z"))
        XCTAssertEqual(value.startDay, "2026-10-17"); XCTAssertEqual(value.endDay, "2026-11-15")
        XCTAssertEqual(value.dayCount, 30); XCTAssertEqual(Set(value.days.map(\.day)).count, 30)
        XCTAssertEqual(value.interval.duration, 30 * 86400 + 3600)
    }

    func testUnpricedCallsStayUnknownAndKnownCostsRemainPartial() {
        let now = date("2026-10-22T06:00:00Z")
        let unknown = PeriodUsage(result: result([day("2026-10-22", cost: nil)]), at: now)
        XCTAssertNil(unknown.totalUSD); XCTAssertNil(unknown.dailyAverageUSD); XCTAssertTrue(unknown.isPartial)
        let mixed = PeriodUsage(result: result([day("2026-10-21", cost: 5), day("2026-10-22", cost: nil)]), at: now)
        XCTAssertEqual(mixed.totalUSD, 5); XCTAssertEqual(mixed.totals.requests, 2)
        XCTAssertEqual(mixed.totals.apiCost.pricedRequests, 1); XCTAssertTrue(mixed.isPartial)
    }

    func testLoadingReadGapsAndInformationalMessagesStayDistinct() {
        let now = date("2026-10-22T06:00:00Z")
        let empty = PeriodUsage(result: result(message: "Informational legacy timing note"), at: now)
        XCTAssertEqual(empty.totalUSD, 0); XCTAssertEqual(empty.dailyAverageUSD, 0)
        XCTAssertFalse(empty.isPartial); XCTAssertEqual(empty.dayCount, 30)
        for source in [result(loading: true), result(gaps: true)] {
            let value = PeriodUsage(result: source, at: now)
            XCTAssertNil(value.totalUSD); XCTAssertNil(value.dailyAverageUSD); XCTAssertTrue(value.isPartial)
        }
        let partial = PeriodUsage(result: result([day("2026-10-22", cost: 3)], loading: true), at: now)
        XCTAssertEqual(partial.totalUSD, 3); XCTAssertTrue(partial.isPartial)
        let gap = PeriodUsage(result: result([day("2026-10-22", cost: 3)], gaps: true), at: now)
        XCTAssertEqual(gap.totalUSD, 3); XCTAssertTrue(gap.isPartial)
    }

    func testExcludedReviewTotalsAreLimitedToTheSamePeriod() {
        var inside = day("2026-10-21", cost: 2), outside = day("2026-09-22", cost: 100)
        inside.excludedAutoReview.requests = 3; inside.excludedAutoReview.outputTokens = 50
        outside.excludedAutoReview.requests = 100; outside.excludedAutoReview.outputTokens = 1000
        let value = PeriodUsage(result: result([inside, outside]), at: date("2026-10-22T06:00:00Z"))
        XCTAssertEqual(value.totalUSD, 2); XCTAssertEqual(value.excludedAutoReview.requests, 3)
        XCTAssertEqual(value.excludedAutoReview.outputTokens, 50)
    }

    func testScannerFeedsTheSameSubagentAndAutoReviewFiltersIntoPeriodTotals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions"), archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        func line(_ type: String, _ payload: [String: Any], dated: Bool = true) throws -> Data {
            var record: [String: Any] = ["type": type, "payload": payload]
            if dated { record["timestamp"] = "2026-10-21T06:00:00Z" }
            var data = try JSONSerialization.data(withJSONObject: record); data.append(10); return data
        }
        func usage(_ thread: String, _ response: String, dated: Bool = true) throws -> Data {
            try line("token_usage_record", ["thread_id": thread, "turn_id": "turn", "response_id": response,
                "usage": ["input_tokens": 100, "cached_input_tokens": 50, "cache_write_input_tokens": 0,
                          "output_tokens": 10, "reasoning_output_tokens": 5]], dated: dated)
        }
        func log(_ id: String, parent: String? = nil, review: Bool = false) throws -> Data {
            var meta: [String: Any] = ["id": id, "source": "vscode"]
            if let parent { meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent]]] }
            var data = try line("session_meta", meta)
            data += try line("event_msg", ["type": "thread_settings_applied", "thread_id": id,
                "thread_settings": ["service_tier": parent == nil ? "default" : "priority"]])
            data += try line("event_msg", ["type": "task_started", "turn_id": "turn"])
            data += try line("turn_context", ["turn_id": "turn", "model": "gpt-6.1-sol"])
            data += try usage(id, "paid")
            if review {
                data += try line("turn_context", ["turn_id": "turn", "model": "codex-auto-review"])
                data += try usage(id, "review")
            }
            return data
        }
        let main = try log("main", review: true)
        try main.write(to: sessions.appendingPathComponent("main.jsonl"))
        try main.write(to: archive.appendingPathComponent("main-copy.jsonl"))
        try log("child", parent: "main").write(to: archive.appendingPathComponent("child.jsonl"))
        let scanner = DailyStatisticsScanner(directory: sessions, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        var scanned = scanner.scan(includeAutoReview: false, force: true)
        for _ in 0..<100 where scanned.isLoading { scanned = scanner.scan(includeAutoReview: false) }
        XCTAssertFalse(scanned.isLoading); XCTAssertFalse(scanned.hasReadGaps)
        let now = date("2026-10-22T06:00:00Z")
        let family = PeriodUsage(result: scanned, at: now)
        XCTAssertEqual(family.totals.requests, 2); XCTAssertEqual(family.totals.apiCost.pricedRequests, 2)
        XCTAssertEqual(family.excludedAutoReview.requests, 1); XCTAssertFalse(family.isPartial)
        let own = PeriodUsage(result: scanner.scan(includeSubagents: false, includeAutoReview: false), at: now)
        XCTAssertEqual(own.totals.requests, 1)
        XCTAssertEqual(family.totalUSD!, own.totalUSD! * 3, accuracy: 1e-12)
        let all = PeriodUsage(result: scanner.scan(includeAutoReview: true), at: now)
        XCTAssertEqual(all.totals.requests, 3); XCTAssertEqual(all.totals.apiCost.pricedRequests, 2)
        XCTAssertTrue(all.isPartial); XCTAssertEqual(all.totalUSD, family.totalUSD)
        // Missing dates cannot be assigned to a range, so the scan reports a
        // numeric coverage gap rather than relying on translated message text.
        let handle = try FileHandle(forWritingTo: sessions.appendingPathComponent("main.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: usage("main", "undated", dated: false)); try handle.close()
        let incomplete = scanner.scan(includeAutoReview: false)
        XCTAssertTrue(incomplete.hasReadGaps)
        XCTAssertTrue(PeriodUsage(result: incomplete, at: now).isPartial)
        let missing = DailyStatisticsScanner(directory: root.appendingPathComponent("missing")).scan()
        XCTAssertTrue(missing.hasReadGaps)
        XCTAssertNil(PeriodUsage(result: missing, at: now).totalUSD)
    }
}
