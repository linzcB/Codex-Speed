import XCTest
@testable import SpeedCore

final class SessionFamilyTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1000)
    var root: URL!
    var directory: URL { root.appendingPathComponent("sessions") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func line(_ type: String, _ payload: [String: Any], at seconds: Double = 0) -> Data {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
            "timestamp": f.string(from: base.addingTimeInterval(seconds))])
        data.append(10); return data
    }
    func metadata(_ id: String, parent: String? = nil, session: String? = nil, encoded: Bool = false) -> Data {
        var payload: [String: Any] = ["id": id, "source": "vscode"]
        if let parent {
            let source = ["subagent": ["thread_spawn": ["parent_thread_id": parent, "agent_path": "/root/\(id)"]]]
            payload["source"] = encoded ? String(data: try! JSONSerialization.data(withJSONObject: source), encoding: .utf8)! as Any : source as Any
        }
        if let session { payload["session_id"] = session }
        return line("session_meta", payload)
    }
    func start(_ turn: String, root: String, at seconds: Double = 0, parent: String? = nil) -> Data {
        var attribution: [String: Any] = ["root_turn_id": root]
        if let parent { attribution["parent_turn_id"] = parent }
        return line("event_msg", ["type": "task_started", "turn_id": turn,
            "root_turn_id": root, "turn_attribution": attribution], at: seconds)
    }
    func usage(_ id: String, turn: String, root: String, output: Int, total: Int? = nil, at seconds: Double = 10) -> Data {
        line("token_usage_record", ["thread_id": id, "turn_id": turn, "root_turn_id": root,
            "response_id": "\(id)-\(turn)-\(seconds)", "usage": ["input_tokens": 10 * output, "output_tokens": output, "reasoning_output_tokens": output / 2],
            "turn_token_usage": ["input_tokens": 10 * output, "output_tokens": output, "reasoning_output_tokens": output / 2],
            "thread_token_usage": ["input_tokens": 10 * (total ?? output), "output_tokens": total ?? output, "reasoning_output_tokens": (total ?? output) / 2]], at: seconds)
    }
    func message(_ turn: String, from: Double, to: Double) -> Data {
        line("event_msg", ["type": "item_completed", "turn_id": turn,
            "item": ["type": "AgentMessage", "id": turn + "-text"],
            "started_at_ms": (1000 + from) * 1000, "completed_at_ms": (1000 + to) * 1000], at: to)
    }
    func end(_ turn: String, at seconds: Double = 11) -> Data {
        line("event_msg", ["type": "task_complete", "turn_id": turn], at: seconds)
    }
    func write(_ name: String, _ data: Data, age: Double = 10, archived: Bool = false) throws {
        let dir = archived ? root.appendingPathComponent("archived_sessions") : directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name + ".jsonl")
        try data.write(to: path)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(age)], ofItemAtPath: path.path)
    }
    func scan(at seconds: Double = 20) -> [SessionSnapshot] {
        LogScanner(directory: directory).scan(at: base.addingTimeInterval(seconds), force: true).sessions
    }

    func testFamilyIncludesNestedChildrenButDoesNotMergeIndependentForkOrOtherChat() throws {
        try write("main", metadata("main") + start("round", root: "round") + usage("main", turn: "round", root: "round", output: 100))
        try write("child", metadata("child", parent: "main") + start("c", root: "round") + usage("child", turn: "c", root: "round", output: 30))
        try write("grandchild", metadata("grandchild", parent: "child", encoded: true) + start("g", root: "round") + usage("grandchild", turn: "g", root: "round", output: 20))
        try write("fork", metadata("fork", session: "main") + start("f", root: "f") + usage("fork", turn: "f", root: "f", output: 800))
        let result = scan()
        let main = try XCTUnwrap(result.first { $0.id == "main" })
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(main.agents.count, 2)
        XCTAssertEqual(main.totalUsage.output, 150)
        XCTAssertEqual(main.totalUsage.input, 1500)
        XCTAssertEqual(main.totalUsage.reasoning, 75)
        XCTAssertEqual(main.latestRound?.usage.output, 150)
        XCTAssertTrue(main.totalsAreComplete)
    }

    func testReusedChildIsChargedToCorrectRootTurnAndLifetimeStillIncludesAll() throws {
        try write("main", metadata("main") + start("old", root: "old") + usage("main", turn: "old", root: "old", output: 100) + end("old") + start("new", root: "new", at: 20) + usage("main", turn: "new", root: "new", output: 200, total: 300, at: 30))
        try write("child", metadata("child", parent: "main") + start("one", root: "old") + usage("child", turn: "one", root: "old", output: 30) + end("one") + start("two", root: "new", at: 20) + usage("child", turn: "two", root: "new", output: 70, total: 100, at: 30))
        let main = try XCTUnwrap(scan(at: 31).first)
        XCTAssertEqual(main.totalUsage.output, 400)
        XCTAssertEqual(main.latestRound?.usage.output, 270)
        XCTAssertEqual(main.round(for: main.turns[0]).usage.output, 130)
    }

    func testInheritedParentMetadataAndUsageDoNotChangeChildIdentityOrDoubleCount() throws {
        try write("main", metadata("main") + start("round", root: "round") + usage("main", turn: "round", root: "round", output: 100))
        let inherited = metadata("main") + start("round", root: "round") + usage("main", turn: "round", root: "round", output: 100)
        let own = start("c", root: "round", at: 20, parent: "round") + usage("child", turn: "c", root: "round", output: 30, at: 30)
        try write("child", metadata("child", parent: "main") + inherited + own)
        let main = try XCTUnwrap(scan(at: 31).first)
        XCTAssertEqual(main.agents.first?.id, "child")
        XCTAssertEqual(main.totalUsage.output, 130)
        XCTAssertEqual(main.latestRound?.childUsage.output, 30)
    }

    func testDuplicateFilesAndArchivedChildCountOnce() throws {
        try write("main", metadata("main") + start("round", root: "round") + usage("main", turn: "round", root: "round", output: 100))
        let child = metadata("child", parent: "main") + start("c", root: "round") + usage("child", turn: "c", root: "round", output: 30)
        try write("child", child, age: 10)
        try write("backup", child, age: 9, archived: true)
        try write("archived-only", metadata("archived-child", parent: "main") + start("a", root: "round") + usage("archived-child", turn: "a", root: "round", output: 20), archived: true)
        let main = try XCTUnwrap(scan().first)
        XCTAssertEqual(main.agents.count, 2)
        XCTAssertEqual(main.totalUsage.output, 150)
    }

    func testMoreThanFortyChildTurnsInOneRootAreNotDropped() throws {
        try write("main", metadata("main") + start("round", root: "round") + usage("main", turn: "round", root: "round", output: 100))
        var child = metadata("child", parent: "main")
        for i in 0..<60 {
            child += start("c\(i)", root: "round", at: Double(i * 2))
            child += usage("child", turn: "c\(i)", root: "round", output: 10, total: (i + 1) * 10, at: Double(i * 2 + 1))
        }
        try write("child", child)
        let main = try XCTUnwrap(scan(at: 125).first)
        XCTAssertEqual(main.latestRound?.childUsage.output, 600)
        XCTAssertEqual(main.latestRound?.usage.output, 700)
    }

    func testGlobalSumAndArithmeticMeanCountEachActiveAgentOnceAndExcludeIdleUnknown() throws {
        try write("main", metadata("main") + start("m", root: "m") + message("m", from: 1, to: 11) + usage("main", turn: "m", root: "m", output: 100, at: 12))
        try write("child", metadata("child", parent: "main") + start("c", root: "m") + message("c", from: 1, to: 21) + usage("child", turn: "c", root: "m", output: 400, at: 22))
        try write("done", metadata("done") + start("d", root: "d") + message("d", from: 1, to: 11) + usage("done", turn: "d", root: "d", output: 900, at: 12) + end("d", at: 13))
        try write("unknown", metadata("unknown") + start("u", root: "u"))
        let sessions = scan(at: 25)
        let global = GlobalSpeed(sessions: sessions, at: base.addingTimeInterval(25), metric: .continuousOutput)
        XCTAssertEqual(global.sum, 30)
        XCTAssertEqual(global.average, 15)
        XCTAssertEqual(global.activeAgents, 3)
        XCTAssertEqual(global.sampledAgents, 2)
        XCTAssertEqual(global.activeChats, 2)
        let idle = GlobalSpeed(sessions: sessions, at: base.addingTimeInterval(1000), metric: .continuousOutput)
        XCTAssertNil(idle.sum); XCTAssertNil(idle.average)
    }

    func testExcludingSubagentsRemovesTheirSpeedAndSampleCountWithoutRemovingOtherChats() throws {
        try write("main", metadata("main") + start("m", root: "m") + message("m", from: 1, to: 11) + usage("main", turn: "m", root: "m", output: 100, at: 12))
        try write("child", metadata("child", parent: "main") + start("c", root: "m") + message("c", from: 1, to: 21) + usage("child", turn: "c", root: "m", output: 600, at: 22))
        try write("other", metadata("other") + start("o", root: "o") + message("o", from: 1, to: 11) + usage("other", turn: "o", root: "o", output: 200, at: 12))
        let sessions = scan(at: 25)
        let now = base.addingTimeInterval(25)
        let combined = GlobalSpeed(sessions: sessions, at: now, metric: .continuousOutput)
        let mainOnly = GlobalSpeed(sessions: sessions, at: now, metric: .continuousOutput, includeSubagents: false)
        XCTAssertEqual(combined.sum, 60)
        XCTAssertEqual(combined.sampledAgents, 3)
        XCTAssertEqual(mainOnly.sum, 30)
        XCTAssertEqual(mainOnly.average, 15)
        XCTAssertEqual(mainOnly.sampledAgents, 2)
        XCTAssertEqual(mainOnly.activeAgents, 2)
        XCTAssertEqual(mainOnly.activeChats, 2)
        XCTAssertEqual(mainOnly.sampleAt, base.addingTimeInterval(11))

        let selected = try XCTUnwrap(sessions.first { $0.id == "main" })
        XCTAssertEqual(GlobalSpeed(sessions: [selected], at: now, metric: .continuousOutput).sum, 40)
        XCTAssertEqual(GlobalSpeed(sessions: [selected], at: now, metric: .continuousOutput, includeSubagents: false).sum, 10)
    }

    func testExcludingSubagentsDoesNotCountChatWithOnlyAnActiveChild() throws {
        try write("main", metadata("main") + start("m", root: "m") + message("m", from: 1, to: 11) + usage("main", turn: "m", root: "m", output: 100, at: 12) + end("m", at: 13))
        try write("child", metadata("child", parent: "main") + start("c", root: "m") + message("c", from: 1, to: 21) + usage("child", turn: "c", root: "m", output: 400, at: 22))
        let sessions = scan(at: 25)
        let now = base.addingTimeInterval(25)
        let combined = GlobalSpeed(sessions: sessions, at: now, metric: .continuousOutput)
        let mainOnly = GlobalSpeed(sessions: sessions, at: now, metric: .continuousOutput, includeSubagents: false)
        XCTAssertEqual(combined.sum, 20)
        XCTAssertEqual(combined.activeChats, 1)
        XCTAssertNil(mainOnly.sum)
        XCTAssertNil(mainOnly.average)
        XCTAssertNil(mainOnly.sampleAt)
        XCTAssertEqual(mainOnly.sampledAgents, 0)
        XCTAssertEqual(mainOnly.activeAgents, 0)
        XCTAssertEqual(mainOnly.activeChats, 0)
    }

    func testExcludingSubagentsFromUsageAndRoundPreservesTheirHistory() throws {
        try write("main", metadata("main") + start("old", root: "old") + usage("main", turn: "old", root: "old", output: 100) + end("old") + start("new", root: "new", at: 20) + usage("main", turn: "new", root: "new", output: 200, total: 300, at: 30))
        try write("child", metadata("child", parent: "main") + start("one", root: "old") + usage("child", turn: "one", root: "old", output: 30) + end("one") + start("two", root: "new", at: 20) + usage("child", turn: "two", root: "new", output: 70, total: 100, at: 30) + end("two", at: 31))
        let main = try XCTUnwrap(scan(at: 32).first)
        let latest = try XCTUnwrap(main.latest)
        let ownRound = main.round(for: latest, includeSubagents: false)
        XCTAssertEqual(main.usage(includeSubagents: false), Usage(input: 3000, output: 300, reasoning: 150))
        XCTAssertEqual(ownRound.usage, Usage(input: 2000, output: 200, reasoning: 100))
        XCTAssertEqual(ownRound.calls, 1)
        XCTAssertEqual(ownRound.childCount, 0)
        XCTAssertTrue(ownRound.children.isEmpty)
        XCTAssertEqual(main.agents.count, 1)
        XCTAssertEqual(main.agents[0].turns.count, 2)
        XCTAssertEqual(main.usage(includeSubagents: true), Usage(input: 4000, output: 400, reasoning: 200))
        XCTAssertEqual(main.latestRound?.usage.output, 270)
        XCTAssertEqual(main.latestRound?.childCount, 1)
        XCTAssertEqual(main.latestRound?.calls, 2)
        XCTAssertEqual(main.round(for: main.turns[0]).childUsage.output, 30)
    }

    func testAllActiveChatsBeyondEightAndChildActivityRevivesOlderParent() throws {
        for i in 0..<10 {
            try write("main\(i)", metadata("main\(i)") + start("r\(i)", root: "r\(i)") + usage("main\(i)", turn: "r\(i)", root: "r\(i)", output: 100), age: Double(i))
        }
        try write("old-main", metadata("old-main") + start("old", root: "old") + usage("old-main", turn: "old", root: "old", output: 100) + end("old"), age: -1000)
        try write("new-child", metadata("new-child", parent: "old-main") + start("c", root: "old") + usage("new-child", turn: "c", root: "old", output: 100), age: 10)
        let result = scan(at: 25)
        XCTAssertEqual(result.count, 11)
        XCTAssertTrue(result.contains { $0.id == "old-main" })
        let global = GlobalSpeed(sessions: result, at: base.addingTimeInterval(25), metric: .wholeTurn)
        XCTAssertEqual(global.activeAgents, 11)
        XCTAssertEqual(global.activeChats, 11)
    }

    func testExplicitlyOwnedInternalAgentIsIncludedInFamilyTotals() throws {
        try write("main", metadata("main") + start("round", root: "round") + usage("main", turn: "round", root: "round", output: 100))
        let meta = line("session_meta", ["id": "guardian", "session_id": "main", "parent_thread_id": "main",
            "thread_source": "guardian_review", "source": ["subagent": ["other": "guardian"]]])
        try write("guardian", meta + start("g", root: "round") + usage("guardian", turn: "g", root: "round", output: 157))
        let main = try XCTUnwrap(scan().first)
        XCTAssertEqual(main.agents.count, 1)
        XCTAssertEqual(main.agents.first?.label, "审核助手")
        XCTAssertEqual(main.totalUsage.output, 257)
        XCTAssertEqual(main.latestRound?.usage.output, 257)
    }

    func testCycleAndUnrelatedInternalSubagentDoNotBecomeFamilyMembers() throws {
        try write("main", metadata("main") + start("round", root: "round") + usage("main", turn: "round", root: "round", output: 100))
        try write("loop-a", metadata("loop-a", parent: "loop-b"))
        try write("loop-b", metadata("loop-b", parent: "loop-a"))
        try write("guardian", line("session_meta", ["id": "guardian", "session_id": "main", "source": ["subagent": "guardian"]]))
        let result = scan()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].agents.isEmpty)
    }
}
