import XCTest
@testable import SpeedCore

final class DailyStatisticsTests: XCTestCase {
    private var root: URL!
    private var modification = 0
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let base = ISO8601DateFormatter().date(from: "2026-01-01T15:59:00Z")!
    private var directory: URL { root.appendingPathComponent("sessions") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func line(_ type: String, _ payload: [String: Any], at seconds: Double = 0, dated: Bool = true) -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record: [String: Any] = ["type": type, "payload": payload]
        if dated { record["timestamp"] = formatter.string(from: base.addingTimeInterval(seconds)) }
        var data = try! JSONSerialization.data(withJSONObject: record); data.append(10); return data
    }
    private func metadata(_ id: String, parent: String? = nil) -> Data {
        var payload: [String: Any] = ["id": id, "source": "vscode"]
        if let parent { payload["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent]]] }
        return line("session_meta", payload)
    }
    private func start(_ turn: String, at seconds: Double = 0) -> Data {
        line("event_msg", ["type": "task_started", "turn_id": turn], at: seconds)
    }
    private func context(_ turn: String, model: String, at seconds: Double = 0) -> Data {
        line("turn_context", ["turn_id": turn, "model": model], at: seconds)
    }
    private func output(_ turn: String, from begin: Double, to end: Double) -> Data {
        line("event_msg", ["type": "item_completed", "turn_id": turn,
            "item": ["type": "AgentMessage", "id": "item-\(end)"],
            "started_at_ms": base.addingTimeInterval(begin).timeIntervalSince1970 * 1000,
            "completed_at_ms": base.addingTimeInterval(end).timeIntervalSince1970 * 1000], at: end)
    }
    private func usage(_ id: String, turn: String, response: String, input: Int, output: Int,
                       cache: Int? = nil, at seconds: Double = 10, dated: Bool = true) -> Data {
        var counts: [String: Any] = ["input_tokens": input, "output_tokens": output, "reasoning_output_tokens": output / 2]
        if let cache { counts["cached_input_tokens"] = cache }
        // Deliberately unrelated cumulative values: daily totals must use usage.
        return line("token_usage_record", ["thread_id": id, "turn_id": turn, "response_id": response,
            "usage": counts, "thread_token_usage": ["input_tokens": 999999, "output_tokens": 99999]], at: seconds, dated: dated)
    }
    private func legacy(_ turn: String, total: Int, last: Int?, cache: Int? = nil, at seconds: Double = 10) -> Data {
        var info: [String: Any] = ["total_token_usage": ["input_tokens": total * 10, "output_tokens": total]]
        if let last {
            var counts = ["input_tokens": last * 10, "output_tokens": last]
            if let cache { counts["input_cached_tokens"] = cache }
            info["last_token_usage"] = counts
        }
        return line("event_msg", ["type": "token_count", "turn_id": turn, "info": info], at: seconds)
    }
    @discardableResult private func write(_ name: String, _ data: Data, archived: Bool = false) throws -> URL {
        let folder = archived ? root.appendingPathComponent("archived_sessions") : directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".jsonl")
        try data.write(to: url)
        modification += 1
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(modification))], ofItemAtPath: url.path)
        return url
    }
    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func finish(_ scanner: DailyStatisticsScanner, includeSubagents: Bool = true, maxBytes: Int = 16 * 1024 * 1024) throws -> DailyScanResult {
        var result = scanner.scan(includeSubagents: includeSubagents, maxBytes: maxBytes, force: true)
        for _ in 0..<2000 where result.isLoading { result = scanner.scan(includeSubagents: includeSubagents, maxBytes: maxBytes) }
        XCTAssertFalse(result.isLoading)
        return result
    }

    func testAutoReviewFilterUsesEachRequestModelAndRestoresWithoutChangingLogs() throws {
        let tier = line("event_msg", ["type": "thread_settings_applied", "thread_id": "main",
            "thread_settings": ["service_tier": "default"]])
        func priced(_ response: String, input: Int, output: Int, cache: Int, at: Double) -> Data {
            line("token_usage_record", ["thread_id": "main", "turn_id": "one", "response_id": response,
                "usage": ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cache,
                          "cache_write_input_tokens": 0, "reasoning_output_tokens": output / 2]], at: at)
        }
        var data = metadata("main") + tier + start("one") + context("one", model: "gpt-6.1-sol")
        data += output("one", from: 1, to: 11) + priced("paid", input: 100, output: 100, cache: 20, at: 12)
        data += context("one", model: "codex-auto-review", at: 13)
        data += output("one", from: 14, to: 24) + priced("review", input: 900, output: 500, cache: 800, at: 25)
        let url = try write("main", data)
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        let all = try XCTUnwrap(try finish(scanner).days.first)
        XCTAssertEqual(all.totals.inputTokens, 1000); XCTAssertEqual(all.totals.outputTokens, 600)
        let filtered = try XCTUnwrap(scanner.scan(includeAutoReview: false).days.first)
        XCTAssertEqual(filtered.totals.inputTokens, 100); XCTAssertEqual(filtered.totals.outputTokens, 100)
        XCTAssertEqual(filtered.totals.cachedInputTokens, 20); XCTAssertEqual(filtered.totals.cacheHitRate, 0.2)
        XCTAssertEqual(filtered.totals.averageSpeed, 10)
        XCTAssertEqual(filtered.totals.requests, 1); XCTAssertEqual(filtered.totals.apiCost.pricedRequests, 1)
        XCTAssertEqual(filtered.models.map(\.model), ["gpt-6.1-sol"])
        XCTAssertEqual(filtered.excludedAutoReview.inputTokens, 900)
        XCTAssertEqual(filtered.excludedAutoReview.outputTokens, 500)
        XCTAssertEqual(filtered.excludedAutoReview.requests, 1)
        XCTAssertEqual(filtered.totals.apiCost, all.totals.apiCost)
        XCTAssertEqual(scanner.scan(includeAutoReview: true).days.first?.totals, all.totals)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testReviewOnlyDayRemainsSelectableAndLateModelIsReclassified() throws {
        let url = try write("main", metadata("main") + start("one")
            + usage("main", turn: "one", response: "r", input: 200, output: 20))
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        XCTAssertEqual(try finish(scanner).days.first?.totals.requests, 1)
        try append(context("one", model: "codex-auto-review", at: 11), to: url)
        let day = try XCTUnwrap(scanner.scan(includeAutoReview: false).days.first)
        XCTAssertEqual(day.totals, DailyTotals())
        XCTAssertTrue(day.models.isEmpty)
        XCTAssertEqual(day.excludedAutoReview.requests, 1)
        XCTAssertEqual(day.excludedAutoReview.outputTokens, 20)
        XCTAssertEqual(scanner.scan(includeAutoReview: true).days.first?.models.first?.model, "codex-auto-review")
    }

    func testAutoReviewAndSubagentSwitchesAreIndependent() throws {
        try write("main", metadata("main") + start("one") + context("one", model: "gpt-6.1-sol")
            + usage("main", turn: "one", response: "main-r", input: 100, output: 10))
        try write("child", metadata("child", parent: "main") + start("child-turn")
            + context("child-turn", model: "codex-auto-review")
            + usage("child", turn: "child-turn", response: "child-r", input: 200, output: 20))
        try write("independent", metadata("independent") + start("other")
            + context("other", model: "codex-auto-review")
            + usage("independent", turn: "other", response: "other-r", input: 300, output: 30))
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        _ = try finish(scanner)
        XCTAssertEqual(scanner.scan(includeAutoReview: false).days.first?.totals.inputTokens, 100)
        XCTAssertEqual(scanner.scan(includeAutoReview: false).days.first?.excludedAutoReview.inputTokens, 500)
        XCTAssertEqual(scanner.scan(includeSubagents: false, includeAutoReview: false).days.first?.excludedAutoReview.inputTokens, 300)
        XCTAssertEqual(scanner.scan(includeSubagents: false, includeAutoReview: true).days.first?.totals.inputTokens, 400)
        XCTAssertEqual(scanner.scan(includeSubagents: true, includeAutoReview: true).days.first?.totals.inputTokens, 600)
    }

    func testAutoReviewRecognitionMatchesModelIDsOnly() {
        XCTAssertTrue(UsageFilter.isAutoReview(model: "codex-auto-review"))
        XCTAssertTrue(UsageFilter.isAutoReview(model: "CODEX-AUTO-REVIEW-2026-10-16"))
        XCTAssertFalse(UsageFilter.isAutoReview(model: "gpt-6.1-sol"))
        XCTAssertFalse(UsageFilter.isAutoReview(model: "my-codex-auto-review"))
        XCTAssertFalse(UsageFilter.isAutoReview(model: "codex-auto-reviewer"))
        XCTAssertFalse(UsageFilter.isAutoReview(model: "guardian"))
    }

    func testRequestDatesCrossShanghaiMidnightWithinOneTurnAndModelsStaySeparate() throws {
        var data = metadata("main") + start("one") + context("one", model: "model-a")
        data += output("one", from: 1, to: 11)
        data += usage("main", turn: "one", response: "r1", input: 100, output: 100, cache: 80, at: 12)
        data += output("one", from: 61, to: 81)
        data += usage("main", turn: "one", response: "r2", input: 200, output: 400, cache: 0, at: 82)
        data += start("two", at: 90) + context("two", model: "model-b", at: 90)
        data += usage("main", turn: "two", response: "r3", input: 300, output: 90, at: 100)
        try write("main", data)
        let result = try finish(DailyStatisticsScanner(directory: directory, timeZone: zone))
        XCTAssertEqual(result.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(result.days.map(\.day), ["2026-01-02", "2026-01-01"])
        let second = result.days[0].totals, first = result.days[1].totals
        XCTAssertEqual(first.inputTokens, 100); XCTAssertEqual(first.outputTokens, 100)
        XCTAssertEqual(first.cacheHitRate, 0.8); XCTAssertEqual(first.averageSpeed, 10)
        XCTAssertEqual(second.inputTokens, 500); XCTAssertEqual(second.outputTokens, 490)
        XCTAssertEqual(second.requests, 2); XCTAssertEqual(second.cacheKnownRequests, 1)
        XCTAssertEqual(second.cacheKnownInputTokens, 200); XCTAssertEqual(second.cacheHitRate, 0)
        XCTAssertEqual(second.timedRequests, 1); XCTAssertEqual(second.timedOutputTokens, 400)
        XCTAssertEqual(second.averageSpeed, 20)
        XCTAssertEqual(result.days[0].models.map(\.model), ["model-a", "model-b"])
        XCTAssertNil(result.days[0].models[1].totals.cacheHitRate)
        XCTAssertNil(result.days[0].models[1].totals.averageSpeed)
    }

    func testLateTurnContextBackfillsOnlyUnresolvedRequestsAcrossScans() throws {
        let url = try write("main", metadata("main") + start("previous") + context("previous", model: "old-model")
            + start("current", at: 1) + usage("main", turn: "current", response: "r1", input: 100, output: 10, at: 10))
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        let before = try finish(scanner)
        XCTAssertEqual(before.days.first?.models.first?.model, "未知模型")
        try append(context("current", model: "new-model", at: 10.029), to: url)
        let after = try finish(scanner)
        XCTAssertEqual(after.days.first?.models.first?.model, "new-model")
        XCTAssertEqual(after.days.first?.totals.requests, 1)
        try append(context("current", model: "third-model", at: 11)
            + usage("main", turn: "current", response: "r2", input: 200, output: 20, at: 12), to: url)
        let changed = try finish(scanner)
        XCTAssertEqual(changed.days.first?.models.map(\.model), ["new-model", "third-model"])
    }

    func testWeightedSpeedIncludesOnlyRequestsWithValidOutputTiming() throws {
        var data = metadata("main") + start("one") + context("one", model: "model-a")
        data += output("one", from: 1, to: 11) + usage("main", turn: "one", response: "r1", input: 100, output: 100, at: 12)
        data += output("one", from: 15, to: 45) + usage("main", turn: "one", response: "r2", input: 100, output: 900, at: 46)
        data += usage("main", turn: "one", response: "r3", input: 100, output: 500, at: 47)
        try write("main", data)
        let totals = try XCTUnwrap(try finish(DailyStatisticsScanner(directory: directory, timeZone: zone)).days.first?.totals)
        XCTAssertEqual(totals.outputTokens, 1500); XCTAssertEqual(totals.requests, 3)
        XCTAssertEqual(totals.timedRequests, 2); XCTAssertEqual(totals.timedOutputTokens, 1000)
        XCTAssertEqual(totals.outputSeconds, 40); XCTAssertEqual(totals.averageSpeed, 25)
    }

    func testInheritedParentRequestsDuplicatesArchivesAndSubagentSwitch() throws {
        let parentUsage = usage("main", turn: "one", response: "parent-r", input: 100, output: 10)
        let parent = metadata("main") + start("one") + context("one", model: "model-a") + parentUsage
        try write("main", parent + parentUsage)
        try write("copy", parent, archived: true)
        let owned = line("event_msg", ["type": "thread_settings_applied", "thread_id": "child"])
            + start("child-turn") + context("child-turn", model: "model-b")
            + usage("child", turn: "child-turn", response: "child-r", input: 30, output: 3)
        try write("child", metadata("child", parent: "main") + parent + owned)
        try write("old", metadata("old") + start("old-turn") + context("old-turn", model: "model-a")
            + usage("old", turn: "old-turn", response: "old-r", input: 20, output: 2), archived: true)
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        let all = try finish(scanner)
        XCTAssertEqual(all.totalFiles, 4); XCTAssertEqual(all.filesRead, 4)
        XCTAssertEqual(all.days.first?.totals.inputTokens, 150); XCTAssertEqual(all.days.first?.totals.requests, 3)
        let own = scanner.scan(includeSubagents: false)
        XCTAssertEqual(own.days.first?.totals.inputTokens, 120); XCTAssertEqual(own.days.first?.totals.requests, 2)
        XCTAssertEqual(scanner.scan().days.first?.totals.inputTokens, 150)
    }

    func testIncrementalPartialRecordTruncationAndSameSizeReplacement() throws {
        let request = usage("main", turn: "one", response: "r1", input: 100, output: 10)
        let url = try write("main", metadata("main") + start("one") + context("one", model: "model-a") + request.dropLast())
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        let pending = scanner.scan(force: true)
        XCTAssertFalse(pending.isLoading); XCTAssertTrue(pending.days.isEmpty)
        XCTAssertTrue(pending.message?.contains(L10n.text("部分日志末尾记录尚未写完，暂未计入；写入完成后会自动补全。")) == true)
        try append(Data([10]), to: url)
        XCTAssertEqual(try finish(scanner).days.first?.totals.inputTokens, 100)
        let replacement = metadata("main") + usage("main", turn: "two", response: "r2", input: 20, output: 2)
        try write("main", replacement)
        XCTAssertEqual(try finish(scanner).days.first?.totals.inputTokens, 20)
        try write("main", metadata("main") + usage("main", turn: "two", response: "r2", input: 30, output: 3))
        XCTAssertEqual(try finish(scanner).days.first?.totals.inputTokens, 30)
    }

    func testEntireHistorySurvivesFortyTurnLimitAndEightMegabyteTailLimit() throws {
        var data = metadata("main")
        let original = usage("main", turn: "turn-0", response: "r0", input: 10, output: 2)
        for index in 0..<45 {
            data += start("turn-\(index)") + context("turn-\(index)", model: "model-a")
            data += usage("main", turn: "turn-\(index)", response: "r\(index)", input: 10, output: 2)
        }
        data += Data(repeating: 32, count: 9 * 1024 * 1024); data.append(10)
        data += original // Duplicate whose turn has already been trimmed.
        data += start("last") + context("last", model: "model-b")
            + usage("main", turn: "last", response: "last-r", input: 40, output: 4)
        try write("main", data)
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        XCTAssertTrue(scanner.scan(maxBytes: 512, force: true).isLoading)
        let result = try finish(scanner, maxBytes: 1024 * 1024)
        XCTAssertEqual(result.days.first?.totals.requests, 46)
        XCTAssertEqual(result.days.first?.totals.inputTokens, 490)
        XCTAssertEqual(result.days.first?.totals.outputTokens, 94)
    }

    func testLegacyVerifiedRequestsHaveUnknownSpeedAndModernReplacesThem() throws {
        let url = try write("main", metadata("main") + start("one") + context("one", model: "model-a")
            + legacy("one", total: 10, last: 10, cache: 70))
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        let old = try finish(scanner)
        XCTAssertEqual(old.days.first?.totals.requests, 1)
        XCTAssertEqual(old.days.first?.totals.cachedInputTokens, 70)
        XCTAssertEqual(old.days.first?.totals.cacheHitRate, 0.7)
        XCTAssertNil(old.days.first?.totals.averageSpeed)
        XCTAssertNotNil(old.message)
        try append(legacy("one", total: 10, last: 10, cache: 70, at: 11), to: url)
        XCTAssertEqual(try finish(scanner).days.first?.totals.requests, 1)
        try append(usage("main", turn: "one", response: "modern-r", input: 150, output: 15, cache: 90, at: 12)
            + legacy("one", total: 15, last: 5, at: 13), to: url)
        let modern = try finish(scanner)
        XCTAssertEqual(modern.days.first?.totals.requests, 1)
        XCTAssertEqual(modern.days.first?.totals.inputTokens, 150)
        XCTAssertEqual(modern.days.first?.totals.outputTokens, 15)
        XCTAssertEqual(modern.days.first?.totals.cachedInputTokens, 90)
        XCTAssertNil(modern.message)
    }

    func testUnverifiableLegacyCumulativeAndMissingTimestampReportCoverage() throws {
        try write("main", metadata("main") + start("one") + context("one", model: "model-a")
            + legacy("one", total: 10000, last: 10)
            + legacy("one", total: 10020, last: 20, at: 12)
            + usage("main", turn: "other", response: "undated-r", input: 300, output: 30, dated: false))
        let result = try finish(DailyStatisticsScanner(directory: directory, timeZone: zone))
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(result.days.first?.totals.requests, 1)
        XCTAssertEqual(result.days.first?.totals.inputTokens, 200)
        XCTAssertEqual(result.days.first?.totals.outputTokens, 20)
        XCTAssertNil(result.days.first?.totals.averageSpeed)
        XCTAssertTrue(result.message?.contains(L10n.text("有 %@ 条旧用量或缺少时间的记录无法可靠归入日期，未计入。", "2")) == true)
    }

    func testUnattributedInternalAgentExcludedButOwnedReviewAgentIncluded() throws {
        let usageData = usage("review", turn: "one", response: "review-r", input: 100, output: 10)
        let owned = line("session_meta", ["id": "review", "parent_thread_id": "main",
            "source": ["subagent": ["other": "guardian"]]])
        let orphan = line("session_meta", ["id": "orphan", "source": ["subagent": "guardian"]])
        try write("review", owned + start("one") + usageData)
        try write("orphan", orphan + start("other")
            + usage("orphan", turn: "other", response: "orphan-r", input: 900, output: 90))
        let scanner = DailyStatisticsScanner(directory: directory, timeZone: zone)
        XCTAssertEqual(try finish(scanner).days.first?.totals.inputTokens, 100)
        XCTAssertTrue(scanner.scan(includeSubagents: false).days.isEmpty)
    }
}
