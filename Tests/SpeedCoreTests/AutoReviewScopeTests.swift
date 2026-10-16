import XCTest
@testable import SpeedCore

final class AutoReviewScopeTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1000)
    func line(_ kind: String, _ payload: [String: Any], at seconds: Double = 0) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try! JSONSerialization.data(withJSONObject: ["type": kind, "payload": payload,
            "timestamp": formatter.string(from: base.addingTimeInterval(seconds))])
        data.append(10); return data
    }
    func event(_ type: String, turn: String = "t", at seconds: Double = 0) -> Data {
        line("event_msg", ["type": type, "turn_id": turn, "root_turn_id": "t"], at: seconds)
    }
    func model(_ name: String, turn: String = "t") -> Data {
        line("turn_context", ["turn_id": turn, "model": name])
    }
    func usage(_ output: Int, response: String, turn: String = "t", at seconds: Double = 10) -> Data {
        line("token_usage_record", ["turn_id": turn, "root_turn_id": "t", "response_id": response,
            "usage": ["input_tokens": output * 10, "output_tokens": output, "reasoning_output_tokens": output / 2]], at: seconds)
    }
    func message(_ id: String, from: Double, to: Double) -> Data {
        line("event_msg", ["type": "item_completed", "turn_id": "t",
            "item": ["type": "AgentMessage", "id": id],
            "started_at_ms": (1000 + from) * 1000, "completed_at_ms": (1000 + to) * 1000], at: to)
    }
    func reader(_ id: String = "main", parent: String? = nil) -> SessionLog {
        let log = SessionLog(url: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
        var meta: [String: Any] = ["id": id, "source": "vscode"]
        if let parent { meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent]]] }
        log.ingest(line("session_meta", meta)); log.modifiedAt = base.addingTimeInterval(30)
        return log
    }
    func testBothSpeedScopesFamilyTotalsAndIndependentSubagentSwitch() throws {
        let main = reader(), child = reader("child", parent: "main"), review = reader("review", parent: "main")
        for (log, name, output, seconds) in [(main, "gpt-6.1-sol", 100, 10.0), (child, "gpt-6.1-sol", 400, 20.0), (review, "codex-auto-review", 900, 10.0)] {
            log.ingest(event("task_started") + model(name) + message(name, from: 1, to: seconds + 1)
                + usage(output, response: name, at: seconds + 2))
        }
        var session = SessionSnapshot(log: main)
        session.agents = [AgentSnapshot(log: child), AgentSnapshot(log: review)]
        let now = base.addingTimeInterval(30)
        let filtered = GlobalSpeed(sessions: [session], at: now, metric: .continuousOutput, includeAutoReview: false)
        XCTAssertEqual(filtered.sum, 30); XCTAssertEqual(filtered.average, 15)
        XCTAssertEqual(filtered.activeAgents, 2); XCTAssertEqual(filtered.sampledAgents, 2)
        XCTAssertEqual(filtered.activeChats, 1)
        XCTAssertEqual(GlobalSpeed(sessions: [session], at: now, metric: .continuousOutput).sum, 120)
        XCTAssertEqual(GlobalSpeed(sessions: [session], at: now, metric: .continuousOutput,
                                   includeSubagents: false, includeAutoReview: false).sum, 10)
        XCTAssertEqual(session.usage(includeSubagents: true, includeAutoReview: false), Usage(input: 5000, output: 500, reasoning: 250))
        XCTAssertEqual(session.usage(includeSubagents: false, includeAutoReview: false).output, 100)
        let round = session.round(for: try XCTUnwrap(session.latest), includeAutoReview: false)
        XCTAssertEqual(round.usage.output, 500); XCTAssertEqual(round.calls, 2); XCTAssertEqual(round.childCount, 1)
        XCTAssertEqual(session.latestRound?.usage.output, 1400)
        XCTAssertEqual(session.agents.count, 2) // Details keep the original records.
        XCTAssertEqual(session.agents[1].totalUsage.output, 900)
    }
    func testMixedTurnFiltersRequestsSamplesAndFirstVisibleDelayWithoutDoubleSubtracting() throws {
        let log = reader()
        log.ingest(event("task_started") + model("codex-auto-review") + message("review", from: 1, to: 11)
            + usage(900, response: "r1", at: 12) + model("gpt-6.1-sol")
            + message("paid", from: 20, to: 30) + usage(200, response: "r2", at: 31))
        let raw = try XCTUnwrap(SessionSnapshot(log: log).latest)
        let filtered = raw.filteringAutoReview(false)
        XCTAssertEqual(raw.usage.output, 1100); XCTAssertEqual(raw.continuousOutputRate, 55)
        XCTAssertEqual(filtered.usage, Usage(input: 2000, output: 200, reasoning: 100))
        XCTAssertEqual(filtered.calls, 1); XCTAssertEqual(filtered.continuousOutputRate, 20)
        XCTAssertEqual(filtered.continuousOutputTokens, 200); XCTAssertEqual(filtered.continuousOutputSeconds, 10)
        XCTAssertEqual(filtered.firstVisibleOutputDelay, 20); XCTAssertNil(filtered.timeToFirstToken)
        XCTAssertEqual(filtered.filteringAutoReview(false).usage, filtered.usage)
        let agent = AgentSnapshot(log: log).filteringAutoReview(false)
        XCTAssertEqual(agent.filteringAutoReview(false).usage(includeAutoReview: false), filtered.usage)
        XCTAssertEqual(AgentSnapshot(log: log).totalUsage.output, 1100)
    }
    func testActiveReviewAfterPaidRequestKeepsPaidLifetimeButLeavesActiveCounts() throws {
        let log = reader()
        log.ingest(event("task_started") + model("gpt-6.1-sol") + usage(100, response: "p")
            + model("codex-auto-review") + usage(300, response: "r", at: 20))
        let agent = AgentSnapshot(log: log)
        XCTAssertTrue(agent.isActive(at: base.addingTimeInterval(30)))
        XCTAssertFalse(agent.isActive(at: base.addingTimeInterval(30), includeAutoReview: false))
        XCTAssertEqual(agent.usage(includeAutoReview: false).output, 100)
        let filtered = try XCTUnwrap(agent.filteringAutoReview(false).latest)
        XCTAssertEqual(filtered.model, "gpt-6.1-sol"); XCTAssertEqual(filtered.calls, 1)
        XCTAssertFalse(agent.filteringAutoReview(false).isCompletelyExcluded)
    }
    func testLateContextOnlyClassifiesUnknownRequestsAndTitlesCannotExcludePaidUsage() throws {
        let log = reader()
        log.label = "codex-auto-review"
        log.ingest(event("task_started") + usage(300, response: "unknown"))
        XCTAssertFalse(log.hasModelUsageBreakdown)
        XCTAssertEqual(AgentSnapshot(log: log).usage(includeAutoReview: false).output, 300)
        log.ingest(model("codex-auto-review"))
        XCTAssertTrue(log.hasModelUsageBreakdown)
        XCTAssertEqual(AgentSnapshot(log: log).usage(includeAutoReview: false).output, 0)
        log.ingest(model("gpt-6.1-sol") + usage(100, response: "paid", at: 20) + model("codex-auto-review-v2"))
        XCTAssertEqual(log.autoReviewUsage.output, 300)
        XCTAssertEqual(AgentSnapshot(log: log).usage(includeAutoReview: false).output, 100)
        XCTAssertEqual(log.turnsWithUsageBreakdown.last?.filteringAutoReview(false).model, "gpt-6.1-sol")
    }
    func testReviewLifetimeSurvivesRetentionAndOldDuplicateDoesNotReviveTurn() throws {
        let log = reader()
        for i in 0..<65 {
            let turn = "t\(i)"
            log.ingest(event("task_started", turn: turn, at: Double(i * 3))
                + model(i < 10 ? "codex-auto-review" : "gpt-6.1-sol", turn: turn)
                + usage(10, response: turn, turn: turn, at: Double(i * 3 + 1))
                + event("task_complete", turn: turn, at: Double(i * 3 + 2)))
        }
        XCTAssertEqual(log.turns.count, 40); XCTAssertEqual(log.lifetimeUsage.output, 650)
        XCTAssertEqual(AgentSnapshot(log: log).usage(includeAutoReview: false).output, 550)
        log.ingest(usage(10, response: "t0", turn: "t0", at: 1000))
        XCTAssertEqual(log.latest?.id, "t64"); XCTAssertEqual(log.turns.count, 40)
        XCTAssertEqual(log.lifetimeUsage.output, 650)
    }
    func testLegacyReplacementIsCountedAndExcludedOnce() throws {
        let log = reader()
        log.ingest(event("task_started") + model("codex-auto-review"))
        log.ingest(line("event_msg", ["type": "token_count", "turn_id": "t", "info": [
            "total_token_usage": ["input_tokens": 3000, "output_tokens": 300, "reasoning_output_tokens": 150]]], at: 10))
        log.ingest(usage(300, response: "modern", at: 11))
        XCTAssertEqual(log.lifetimeUsage.output, 300); XCTAssertEqual(log.autoReviewUsage.output, 300)
        let turn = try XCTUnwrap(log.turnsWithUsageBreakdown.last?.filteringAutoReview(false))
        XCTAssertFalse(turn.hasUsage); XCTAssertEqual(turn.calls, 0); XCTAssertEqual(turn.usage, Usage())
    }
    func testTailReaderReplaysPrefixForModelExclusionWithoutChangingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = line("session_meta", ["id": "large", "source": "vscode"])
            + event("task_started", turn: "old") + model("codex-auto-review", turn: "old")
            + usage(300, response: "old", turn: "old") + event("task_complete", turn: "old", at: 11)
        let padding = line("unrelated", ["text": String(repeating: "x", count: 1024 * 1024)])
        for _ in 0..<10 { data += padding }
        data += event("task_started", at: 20) + model("gpt-6.1-sol") + usage(100, response: "paid", at: 30)
        try data.write(to: url)
        let log = SessionLog(url: url)
        log.refresh(); XCTAssertTrue(log.hasSkippedHistory)
        log.refresh(maxBytes: 512 * 1024, requiresModelUsage: true)
        XCTAssertTrue(log.hasUnreadBytes); XCTAssertFalse(log.hasSkippedHistory)
        for _ in 0..<100 where log.hasUnreadBytes { log.refresh(maxBytes: 512 * 1024, requiresModelUsage: true) }
        XCTAssertFalse(log.hasUnreadBytes); XCTAssertTrue(log.hasModelUsageBreakdown)
        XCTAssertEqual(log.lifetimeUsage.output, 400)
        XCTAssertEqual(AgentSnapshot(log: log).usage(includeAutoReview: false).output, 100)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
