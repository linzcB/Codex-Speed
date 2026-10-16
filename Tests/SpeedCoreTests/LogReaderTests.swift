import XCTest
@testable import SpeedCore

final class LogReaderTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)
    func record(_ kind: String, _ payload: [String: Any], seconds: Double) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let obj: [String: Any] = ["type": kind, "timestamp": formatter.string(from: start.addingTimeInterval(seconds)), "payload": payload]
        var data = try! JSONSerialization.data(withJSONObject: obj)
        data.append(10); return data
    }
    func event(_ type: String, turn: String = "a", seconds: Double = 0, extra: [String: Any] = [:]) -> Data {
        var obj = extra; obj["type"] = type; obj["turn_id"] = turn
        return record("event_msg", obj, seconds: seconds)
    }
    func usage(_ output: Int, turn: String = "a", response: String = "r1", seconds: Double = 10,
               cumulative: Int? = nil) -> Data {
        var payload: [String: Any] = ["turn_id": turn, "response_id": response,
            "usage": ["input_tokens": 1000, "output_tokens": output, "reasoning_output_tokens": output / 2]]
        if let cumulative {
            payload["turn_token_usage"] = ["input_tokens": 2000, "output_tokens": cumulative, "reasoning_output_tokens": cumulative / 2]
        }
        return record("token_usage_record", payload, seconds: seconds)
    }
    func legacy(_ output: Int, turn: String = "a", seconds: Double = 10) -> Data {
        event("token_count", turn: turn, seconds: seconds, extra: ["info": [
            "total_token_usage": ["input_tokens": output * 10, "output_tokens": output, "reasoning_output_tokens": output / 2],
            "last_token_usage": ["input_tokens": 100, "output_tokens": 10, "reasoning_output_tokens": 5]]])
    }
    func reader() -> SessionLog { SessionLog(url: URL(fileURLWithPath: "/tmp/test.jsonl")) }

    func testCoexistingFormatsAndDuplicateResponseNotDoubleCounted() {
        let log = reader()
        log.ingest(event("task_started"))
        log.ingest(usage(100))
        log.ingest(legacy(100))
        log.ingest(usage(100))
        log.ingest(usage(150, response: "r2", seconds: 20, cumulative: 250))
        log.ingest(legacy(250, seconds: 20))
        log.ingest(event("task_complete", seconds: 25, extra: ["duration_ms": 25000]))
        XCTAssertEqual(log.latest?.usage.output, 250)
        XCTAssertEqual(log.latest?.usage.reasoning, 125)
        XCTAssertEqual(log.latest?.calls, 2)
        XCTAssertEqual(log.latest?.rate(at: start.addingTimeInterval(999)), 10)
    }
    func testCountersResetAtNewTurnAndLegacyDuplicatesIgnored() {
        let log = reader()
        log.ingest(event("task_started"))
        log.ingest(legacy(100)); log.ingest(legacy(100))
        log.ingest(event("task_complete", seconds: 20))
        log.ingest(event("task_started", turn: "b", seconds: 100))
        log.ingest(legacy(150, turn: "b", seconds: 110))
        XCTAssertEqual(log.latest?.usage.output, 50)
        XCTAssertEqual(log.latest?.calls, 1)
        XCTAssertEqual(log.latest?.rate(at: start.addingTimeInterval(110)), 5)
        XCTAssertEqual(log.turns.first?.calls, 1)
    }
    func testPartialJSONIsNotLostOrCountedUntilNewline() {
        let log = reader()
        log.ingest(event("task_started"))
        let data = usage(60)
        log.ingest(Data(data.prefix(data.count / 2)))
        XCTAssertFalse(log.latest!.hasUsage)
        log.ingest(Data(data.dropFirst(data.count / 2).dropLast()))
        XCTAssertFalse(log.latest!.hasUsage)
        log.ingest(Data([10]))
        XCTAssertEqual(log.latest?.usage.output, 60)
    }
    func testTruncatedTailDoesNotInventDuration() {
        let log = reader()
        log.ingest(usage(500, cumulative: 5000))
        XCTAssertNil(log.latest?.rate(at: start.addingTimeInterval(20)))
        log.ingest(event("task_complete", seconds: 30, extra: ["duration_ms": 10000]))
        XCTAssertEqual(log.latest?.rate(at: start.addingTimeInterval(50)), 500)
        let old = reader()
        old.ingest(legacy(5000))
        old.ingest(event("task_complete", seconds: 30, extra: ["duration_ms": 10000]))
        XCTAssertNil(old.latest?.rate(at: start.addingTimeInterval(50)))
    }
    func testInterruptedTurnFreezesAndNextTurnDoesNotInheritUsage() {
        let log = reader()
        log.ingest(event("task_started")); log.ingest(usage(100))
        log.ingest(event("turn_aborted", seconds: 20))
        XCTAssertTrue(log.latest!.interrupted)
        XCTAssertEqual(log.latest?.rate(at: start.addingTimeInterval(500)), 5)
        log.ingest(event("task_started", turn: "b", seconds: 30))
        XCTAssertEqual(log.latest?.usage.output, 0)
        XCTAssertNil(log.latest?.rate(at: start.addingTimeInterval(31)))
    }
    func testParallelToolTimeUsesWallTimeOnce() {
        let log = reader()
        log.ingest(event("task_started"))
        for i in 0..<2 {
            log.ingest(event("item_completed", seconds: 15, extra: ["item": ["type": "CommandExecution", "id": "tool\(i)"],
                "started_at_ms": 1005000, "completed_at_ms": 1015000]))
        }
        log.ingest(usage(200, seconds: 20))
        log.ingest(event("task_complete", seconds: 20))
        XCTAssertEqual(log.latest?.rate(at: start.addingTimeInterval(30)), 10)
    }
    func testMalformedLinesAndNullUsageAreIgnored() {
        let log = reader()
        log.ingest(Data("garbage\n{}\n".utf8))
        log.ingest(event("task_started"))
        log.ingest(event("token_count", extra: ["info": NSNull()]))
        log.ingest(usage(100))
        XCTAssertEqual(log.latest?.usage.output, 100)
    }
    func testIncrementalDiskReadAndTruncation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout.jsonl")
        try event("task_started").write(to: url)
        let log = SessionLog(url: url); log.refresh()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: usage(150)); try handle.close()
        log.refresh(); log.refresh()
        XCTAssertEqual(log.latest?.usage.output, 150)
        XCTAssertEqual(log.latest?.calls, 1)
        try event("task_started", turn: "new").write(to: url)
        log.refresh()
        XCTAssertEqual(log.latest?.id, "new")
        XCTAssertEqual(log.latest?.usage.output, 0)
    }
    func testMissingDirectoryReportsProblem() {
        let scanner = LogScanner(directory: URL(fileURLWithPath: "/no-such-codex-directory-\(UUID().uuidString)"))
        let result = scanner.scan()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNotNil(result.message)
    }
}
