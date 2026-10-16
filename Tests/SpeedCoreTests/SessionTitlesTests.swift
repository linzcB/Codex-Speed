import XCTest
import SQLite3
@testable import SpeedCore

final class SessionTitlesTests: XCTestCase {
    private var root: URL!
    private var sessions: URL { root.appendingPathComponent("sessions") }
    private var index: URL { root.appendingPathComponent("session_index.jsonl") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }
    private func jsonLine(_ record: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(10)
        return data
    }
    private func chat(_ id: String, source: Any = "vscode", modifiedAt: Date = Date()) throws {
        let url = sessions.appendingPathComponent("\(id).jsonl")
        try jsonLine(["type": "session_meta", "payload": [
            "id": id, "cwd": "/some/workspace-slug", "source": source
        ]]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
    private func title(_ id: String, _ name: String) throws -> Data {
        try jsonLine(["id": id, "thread_name": name, "updated_at": "2026-10-11T01:00:00Z"])
    }
    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: index)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    private func database(_ schema: String) throws -> OpaquePointer {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return db
    }

    func testDatabaseDisplayNameWinsAndCommittedWALRenameAppearsWithoutNewLogWrites() throws {
        try chat("chat-1")
        try title("chat-1", "旧索引标题").write(to: index)
        let db = try database("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT);
            INSERT INTO threads VALUES ('chat-1', '测试会话标题', 'This is a raw initial prompt');
            """)
        defer { sqlite3_close(db) }
        let scanner = LogScanner(directory: sessions)
        let now = Date()
        let before = scanner.scan(at: now, force: true)
        XCTAssertEqual(before.sessions.first?.label, "测试会话标题")
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET name = '我重命名的聊天' WHERE id = 'chat-1'",
                                    nil, nil, nil), SQLITE_OK)
        let after = scanner.scan(at: now.addingTimeInterval(1))
        XCTAssertEqual(after.sessions.first?.label, "我重命名的聊天")
        XCTAssertEqual(after.sessions.first?.id, before.sessions.first?.id)
        XCTAssertEqual(after.sessions.first?.modifiedAt, before.sessions.first?.modifiedAt)
    }

    func testIndexFallbackHandlesPartialAppendAndRenames() throws {
        try chat("chat-1")
        try title("chat-1", "原始标题").write(to: index)
        let scanner = LogScanner(directory: sessions)
        XCTAssertEqual(scanner.scan(force: true).sessions.first?.label, "原始标题")
        let renamed = try title("chat-1", "已改名的会话")
        try append(Data(renamed.dropLast()))
        XCTAssertEqual(scanner.scan().sessions.first?.label, "原始标题")
        try append(Data([10]))
        XCTAssertEqual(scanner.scan().sessions.first?.label, "已改名的会话")
        try title("chat-1", "整个索引被替换").write(to: index, options: .atomic)
        XCTAssertEqual(scanner.scan().sessions.first?.label, "整个索引被替换")
    }

    func testOlderDatabaseUsesIndexAndNeverUsesRawPromptOrWorkspaceAsTitle() throws {
        try chat("chat-1")
        try chat("chat-2")
        let db = try database("""
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT);
            INSERT INTO threads VALUES ('chat-1', 'Raw prompt must not become the display name');
            """)
        defer { sqlite3_close(db) }
        try title("chat-1", "兼容旧版的聊天名").write(to: index)
        let result = LogScanner(directory: sessions).scan(force: true)
        XCTAssertEqual(result.sessions.first { $0.id == "chat-1" }?.label, "兼容旧版的聊天名")
        XCTAssertEqual(result.sessions.first { $0.id == "chat-2" }?.label, "未命名会话")
    }

    func testInternalTasksDoNotDisplaceRecentEightHumanChats() throws {
        let now = Date()
        var names = Data()
        for i in 0..<8 {
            try chat("human-\(i)", modifiedAt: now.addingTimeInterval(Double(-100 - i)))
            names.append(try title("human-\(i)", "聊天 \(i)"))
        }
        for i in 0..<10 {
            try chat("guardian-\(i)", source: ["subagent": ["other": "guardian"]],
                     modifiedAt: now.addingTimeInterval(Double(-i)))
        }
        try chat("serialized-agent", source: "{\"subagent\":{\"other\":\"guardian\"}}")
        try names.write(to: index)
        let scanner = LogScanner(directory: sessions)
        let result = scanner.scan(at: now, force: true)
        XCTAssertEqual(result.sessions.count, 8)
        XCTAssertEqual(Set(result.sessions.map(\.id)), Set((0..<8).map { "human-\($0)" }))
        XCTAssertEqual(scanner.scan(at: now.addingTimeInterval(11)).sessions.count, 8)
    }

    func testHumanChatNamedGuardianIsKeptAndTitlesMatchTheirOwnIDs() throws {
        try chat("chat-1"); try chat("chat-2")
        var data = try title("chat-1", "Guardian review")
        data.append(try title("chat-2", "第二个聊天"))
        data.append(Data("malformed entry\n".utf8))
        try data.write(to: index)
        let result = LogScanner(directory: sessions).scan(force: true)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.first { $0.id == "chat-1" }?.label, "Guardian review")
        XCTAssertEqual(result.sessions.first { $0.id == "chat-2" }?.label, "第二个聊天")
    }
}
