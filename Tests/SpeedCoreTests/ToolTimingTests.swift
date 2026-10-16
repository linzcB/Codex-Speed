import XCTest
@testable import SpeedCore

final class ToolTimingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1000)
    private func log() -> SessionLog { SessionLog(url: URL(fileURLWithPath: "/tmp/timing.jsonl")) }
    private func record(_ kind: String, _ payload: [String: Any], at seconds: Double) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try! JSONSerialization.data(withJSONObject: [
            "type": kind, "payload": payload, "timestamp": formatter.string(from: base.addingTimeInterval(seconds))
        ])
        data.append(10)
        return data
    }
    private func event(_ type: String, at seconds: Double = 0, turn: String = "a",
                       extra: [String: Any] = [:]) -> Data {
        var payload = extra; payload["type"] = type; payload["turn_id"] = turn
        return record("event_msg", payload, at: seconds)
    }
    private func usage(_ output: Int, at seconds: Double, response: String = "r1", turn: String = "a") -> Data {
        record("token_usage_record", ["turn_id": turn, "response_id": response,
            "usage": ["output_tokens": output]], at: seconds)
    }
    private func tool(_ id: String, from start: Double, to end: Double, type: String = "CommandExecution") -> Data {
        event("item_completed", at: end, extra: ["item": ["id": id, "type": type],
            "started_at_ms": (1000 + start) * 1000, "completed_at_ms": (1000 + end) * 1000])
    }
    private func call(_ id: String, type: String, at seconds: Double) -> Data {
        record("response_item", ["type": type, "call_id": id], at: seconds)
    }

    func testOverlappingAndDuplicateToolIntervalsAreSubtractedOnce() throws {
        let reader = log()
        reader.ingest(event("task_started"))
        reader.ingest(tool("one", from: 2, to: 12))
        reader.ingest(tool("two", from: 5, to: 15, type: "McpToolCall"))
        reader.ingest(tool("two", from: 5, to: 15, type: "McpToolCall"))
        reader.ingest(usage(270, at: 40))
        let turn = try XCTUnwrap(reader.latest)
        XCTAssertEqual(turn.toolSecondsToSample, 13)
        XCTAssertEqual(turn.nonToolSecondsToSample, 27)
        XCTAssertEqual(turn.rateExcludingTools, 10)
        XCTAssertEqual(turn.rate(at: base.addingTimeInterval(50)), 5.4)
    }

    func testFunctionAndCustomToolEnvelopesIncludeClientWaitWithoutDoubleCountingChildTools() {
        let reader = log()
        reader.ingest(event("task_started"))
        reader.ingest(call("parent", type: "function_call", at: 5))
        reader.ingest(tool("child", from: 8, to: 15))
        reader.ingest(call("parent", type: "function_call_output", at: 25))
        reader.ingest(call("patch", type: "custom_tool_call", at: 28))
        reader.ingest(tool("patch-item", from: 29, to: 30, type: "FileChange"))
        reader.ingest(call("patch", type: "custom_tool_call_output", at: 32))
        reader.ingest(usage(160, at: 40))
        XCTAssertEqual(reader.latest?.toolSecondsToSample, 24)
        XCTAssertEqual(reader.latest?.nonToolSecondsToSample, 16)
        XCTAssertEqual(reader.latest?.rateExcludingTools, 10)
    }

    func testUnfinishedToolDoesNotLowerRateBetweenCompletedUsageSamples() throws {
        let reader = log()
        reader.ingest(event("task_started"))
        reader.ingest(usage(100, at: 10))
        reader.ingest(call("slow", type: "function_call", at: 11))
        var turn = try XCTUnwrap(reader.latest)
        XCTAssertEqual(turn.toolSecondsToSample, 0)
        XCTAssertEqual(turn.rate(at: base.addingTimeInterval(100), metric: .excludingTools), 10)
        XCTAssertEqual(turn.rate(at: base.addingTimeInterval(200), metric: .excludingTools), 10)
        reader.ingest(call("slow", type: "function_call_output", at: 111))
        reader.ingest(usage(100, at: 120, response: "r2"))
        turn = try XCTUnwrap(reader.latest)
        XCTAssertEqual(turn.toolSecondsToSample, 100)
        XCTAssertEqual(turn.nonToolSecondsToSample, 20)
        XCTAssertEqual(turn.rateExcludingTools, 10)
    }

    func testTailWithRecoveredTurnDurationStillDoesNotInventMissingToolTiming() {
        let reader = log()
        reader.ingest(usage(100, at: 30))
        reader.ingest(event("task_complete", at: 31, extra: ["duration_ms": 20000]))
        XCTAssertTrue(reader.latest!.hasKnownStart)
        XCTAssertFalse(reader.latest!.hasCompleteTimeline)
        XCTAssertEqual(reader.latest?.rate(at: base.addingTimeInterval(100)), 5)
        XCTAssertNil(reader.latest?.rateExcludingTools)
    }

    func testLateResultOfAbortedTurnDoesNotChargeTheNextTurn() {
        let reader = log()
        reader.ingest(event("task_started"))
        reader.ingest(call("old-tool", type: "function_call", at: 2))
        reader.ingest(event("turn_aborted", at: 3))
        reader.ingest(event("task_started", at: 4, turn: "b"))
        reader.ingest(call("old-tool", type: "function_call_output", at: 10))
        reader.ingest(usage(100, at: 14, turn: "b"))
        XCTAssertEqual(reader.latest?.toolSecondsToSample, 0)
        XCTAssertEqual(reader.latest?.rateExcludingTools, 10)
        XCTAssertEqual(reader.turns.first?.toolIntervals["call:old-tool"]?.end, base.addingTimeInterval(10))
    }

    func testReasoningMessagesAndCompactionAreNotClassifiedAsToolExecution() {
        let reader = log()
        reader.ingest(event("task_started"))
        reader.ingest(tool("reasoning", from: 0, to: 10, type: "Reasoning"))
        reader.ingest(tool("answer", from: 10, to: 15, type: "AgentMessage"))
        reader.ingest(tool("compact", from: 15, to: 18, type: "ContextCompaction"))
        reader.ingest(tool("invalid", from: 12, to: 2))
        reader.ingest(usage(200, at: 20))
        XCTAssertEqual(reader.latest?.toolSecondsToSample, 0)
        XCTAssertEqual(reader.latest?.rateExcludingTools, 10)
    }

    func testToolIntervalsAreClippedToTheCountedSampleRange() {
        let reader = log()
        reader.ingest(event("task_started"))
        reader.ingest(tool("before", from: -10, to: 3))
        reader.ingest(tool("after", from: 8, to: 30))
        reader.ingest(usage(50, at: 10))
        XCTAssertEqual(reader.latest?.toolSecondsToSample, 5)
        XCTAssertEqual(reader.latest?.nonToolSecondsToSample, 5)
        XCTAssertEqual(reader.latest?.rateExcludingTools, 10)
    }

    func testModelGenerationOverlappingBackgroundToolsIsPreserved() {
        let reader = log()
        reader.ingest(event("task_started"))
        reader.ingest(tool("background", from: 5, to: 50))
        reader.ingest(tool("nested", from: 20, to: 45, type: "McpToolCall"))
        reader.ingest(tool("reasoning", from: 10, to: 40, type: "Reasoning"))
        reader.ingest(tool("message", from: 38, to: 42, type: "AgentMessage"))
        reader.ingest(usage(370, at: 50))
        XCTAssertEqual(reader.latest?.toolSecondsToSample, 13)
        XCTAssertEqual(reader.latest?.nonToolSecondsToSample, 37)
        XCTAssertEqual(reader.latest?.rateExcludingTools, 10)
    }
}
