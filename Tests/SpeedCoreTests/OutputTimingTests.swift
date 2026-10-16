import XCTest
@testable import SpeedCore

final class OutputTimingTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1000)
    func reader() -> SessionLog { SessionLog(url: URL(fileURLWithPath: "/tmp/output-timing.jsonl")) }
    func record(_ kind: String, _ payload: [String: Any], at seconds: Double) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try! JSONSerialization.data(withJSONObject: ["type": kind, "payload": payload,
            "timestamp": formatter.string(from: base.addingTimeInterval(seconds))])
        data.append(10); return data
    }
    func event(_ type: String, at seconds: Double = 0, turn: String = "a", extra: [String: Any] = [:]) -> Data {
        var payload = extra; payload["type"] = type; payload["turn_id"] = turn
        return record("event_msg", payload, at: seconds)
    }
    func item(_ id: String, _ type: String = "AgentMessage", from start: Double, to end: Double,
              turn: String = "a", receivedAt: Double? = nil) -> Data {
        event("item_completed", at: receivedAt ?? end, turn: turn, extra: [
            "item": ["id": id, "type": type], "started_at_ms": (1000 + start) * 1000,
            "completed_at_ms": (1000 + end) * 1000])
    }
    func usage(_ tokens: Int, at seconds: Double, response: String = "r1", turn: String = "a", total: Int? = nil) -> Data {
        var payload: [String: Any] = ["response_id": response, "turn_id": turn, "usage": ["output_tokens": tokens]]
        if let total { payload["turn_token_usage"] = ["output_tokens": total] }
        return record("token_usage_record", payload, at: seconds)
    }

    func testExcludesEveryCallWaitAndToolsAndUsesDurationWeightedRate() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(item("one", from: 10, to: 20))
        log.ingest(usage(100, at: 22)) // accounting delay also excluded
        log.ingest(item("tool", "CommandExecution", from: 22, to: 100))
        log.ingest(item("two", from: 120, to: 140)) // fresh 20-second wait
        log.ingest(usage(400, at: 141, response: "r2", total: 500))
        XCTAssertEqual(log.latest?.continuousOutputTokens, 500)
        XCTAssertEqual(log.latest?.continuousOutputSeconds, 30)
        XCTAssertEqual(log.latest?.continuousOutputCalls, 2)
        XCTAssertEqual(log.latest!.continuousOutputRate!, 500.0 / 30, accuracy: 0.0001)
        XCTAssertEqual(log.latest?.rate(at: base.addingTimeInterval(10000), metric: .continuousOutput), log.latest?.continuousOutputRate)
    }

    func testMissingStartSkipsBothTimeAndTokensInsteadOfInflatingRate() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(record("response_item", ["type": "function_call", "call_id": "c"], at: 10))
        log.ingest(usage(900, at: 11))
        XCTAssertNil(log.latest?.continuousOutputRate)
        log.ingest(item("text", from: 30, to: 40))
        log.ingest(usage(100, at: 42, response: "r2", total: 1000))
        XCTAssertEqual(log.latest?.usage.output, 1000)
        XCTAssertEqual(log.latest?.continuousOutputTokens, 100)
        XCTAssertEqual(log.latest?.continuousOutputCalls, 1)
        XCTAssertEqual(log.latest?.continuousOutputRate, 10)
    }

    func testReasoningAndGeneratedToolArgumentsIncludedButExecutionNotIncluded() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(item("reason", "Reasoning", from: 10, to: 15))
        log.ingest(record("response_item", ["type": "custom_tool_call", "call_id": "c"], at: 20))
        log.ingest(item("tool", "CommandExecution", from: 20, to: 50))
        log.ingest(usage(500, at: 51))
        XCTAssertEqual(log.latest?.continuousOutputSeconds, 10)
        XCTAssertEqual(log.latest?.continuousOutputRate, 50)
    }

    func testNativeToolInsideResponseIsExcludedAndOverlappingGenerationPreserved() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(item("reason", "Reasoning", from: 10, to: 15))
        log.ingest(item("search", "WebSearch", from: 15, to: 35))
        log.ingest(item("text", from: 30, to: 40))
        log.ingest(usage(300, at: 41))
        XCTAssertEqual(log.latest?.continuousOutputSeconds, 15)
        XCTAssertEqual(log.latest?.continuousOutputRate, 20)
    }

    func testDuplicateUsageAndLateItemDoNotContaminateNextCall() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(item("one", from: 10, to: 20))
        log.ingest(usage(100, at: 21)); log.ingest(usage(100, at: 21))
        log.ingest(item("one", from: 10, to: 20, receivedAt: 23))
        log.ingest(usage(900, at: 25, response: "r2"))
        XCTAssertEqual(log.latest?.continuousOutputTokens, 100)
        XCTAssertEqual(log.latest?.continuousOutputCalls, 1)
        XCTAssertEqual(log.latest?.calls, 2)
    }

    func testTruncatedFirstResponseSkippedButNextCompleteResponseRecovered() {
        let log = reader()
        log.ingest(item("tail", from: 10, to: 20))
        log.ingest(usage(900, at: 21, total: 9000))
        XCTAssertNil(log.latest?.continuousOutputRate)
        log.ingest(item("next", from: 30, to: 40))
        log.ingest(usage(100, at: 41, response: "r2", total: 9100))
        XCTAssertEqual(log.latest?.continuousOutputTokens, 100)
        XCTAssertEqual(log.latest?.continuousOutputRate, 10)
        XCTAssertNil(log.latest?.firstVisibleOutputDelay)
    }

    func testFirstVisibleDelayDiffersFromFirstReasoningTokenAndDoesNotReset() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(item("reason", "Reasoning", from: 2, to: 8))
        XCTAssertNil(log.latest?.firstVisibleOutputDelay)
        log.ingest(item("message", from: 10, to: 12))
        XCTAssertEqual(log.latest?.firstVisibleOutputDelay, 10)
        log.ingest(item("later-message", from: 20, to: 22))
        log.ingest(usage(100, at: 23))
        log.ingest(event("task_complete", at: 24, extra: ["duration_ms": 24000, "time_to_first_token_ms": 2050]))
        XCTAssertEqual(log.latest?.timeToFirstToken, 2.05)
        XCTAssertEqual(log.latest?.firstVisibleOutputDelay, 10)
        log.ingest(event("task_started", at: 100, turn: "b"))
        XCTAssertNil(log.latest?.firstVisibleOutputDelay)
        XCTAssertNil(log.latest?.continuousOutputRate)
    }

    func testSingleTimestampOrInvalidWindowDoesNotInventInfiniteSpeed() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(item("buffered", from: 10, to: 10))
        log.ingest(usage(100, at: 11))
        log.ingest(item("backwards", from: 30, to: 20))
        log.ingest(usage(100, at: 40, response: "r2"))
        XCTAssertNil(log.latest?.continuousOutputRate)
        XCTAssertEqual(log.latest?.continuousOutputTokens, 0)
    }

    func testUserMessageAndToolOutputAreNotGenerationBoundaries() {
        let log = reader(); log.ingest(event("task_started"))
        log.ingest(item("text", from: 10, to: 20))
        log.ingest(record("response_item", ["type": "message", "role": "user"], at: 30))
        log.ingest(record("response_item", ["type": "function_call_output", "call_id": "other"], at: 40))
        log.ingest(usage(100, at: 50))
        XCTAssertEqual(log.latest?.continuousOutputSeconds, 10)
    }
}
