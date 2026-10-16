import Foundation
import SQLite3

@main struct Benchmark {
 static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-speed-benchmark-" + UUID().uuidString)
  let sessions = root.appendingPathComponent("sessions")
  try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let now = Date()
  let count = max(1, Int(CommandLine.arguments.dropFirst().first ?? "1000") ?? 1000)
  func record(_ type: String, _ payload: [String: Any]) throws -> Data {
   var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-10-10T01:00:00.000Z", "payload": payload])
   data.append(10); return data
  }
  for i in 0..<count {
   for agent in 0..<4 {
    let id = "chat-\(i)-\(agent)"
    var meta: [String: Any] = ["id": id, "source": "vscode"]
    if agent > 0 { meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": "chat-\(i)-0"]]] }
    let data = try record("session_meta", meta)
    let file = sessions.appendingPathComponent(id + ".jsonl")
    try data.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600 - Double(i))], ofItemAtPath: file.path)
   }
  }
  var db: OpaquePointer?
  sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db)
  sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT)", nil, nil, nil)
  for i in 0..<count { sqlite3_exec(db, "INSERT INTO threads VALUES ('chat-\(i)-0', 'Demo chat \(i)')", nil, nil, nil) }
  sqlite3_close(db)
  let scanner = LogScanner(directory: sessions)
  func measure(_ name: String, count: Int, _ work: () -> Void) {
   let start = ProcessInfo.processInfo.systemUptime
   for _ in 0..<count { work() }
   print("\(name): \(String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(count))) ms/op (\(count) iterations)")
  }
  print("Generated fixture: \(count) chats, \(count * 4) log files; no user data")
  measure("discovery", count: 3) { _ = scanner.scan(at: now, force: true) }
  measure("unchanged_scan", count: 100) { _ = scanner.scan(at: now) }
  let localizer = AppLocalizer(language: .english)
  measure("localized_1000_strings", count: 10) { for _ in 0..<1000 { _ = localizer.text("当前会话") } }
 }
}
