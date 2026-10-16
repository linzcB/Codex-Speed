import Foundation
import SQLite3

/// Reads display names from the selected Codex home's own metadata. The database
/// is opened read-only on every scan so committed renames in its WAL are visible.
/// Older versions or copied logs can still use the lightweight JSONL index.
final class SessionTitles {
    let directory: URL
    private var indexNames: [String: String] = [:]
    private var indexModifiedAt: Date?
    private var indexSize: UInt64?
    private static let indexLimit = 8 * 1024 * 1024

    init(directory: URL) { self.directory = directory }

    func names(for ids: [String]) -> [String: String] {
        refreshIndex()
        var result = indexNames.filter { ids.contains($0.key) }
        guard !ids.isEmpty, let databaseURL = databaseURL() else { return result }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return result
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)
        var statement: OpaquePointer?
        // `title` is the initial prompt in some Codex versions. Only `name` is
        // the desktop's display title; never substitute a raw prompt for it.
        guard sqlite3_prepare_v2(database, "SELECT name FROM threads WHERE id = ?", -1,
                                &statement, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            if sqlite3_step(statement) == SQLITE_ROW,
               let bytes = sqlite3_column_text(statement, 0),
               let name = Self.displayName(String(cString: bytes)) {
                result[id] = name
            }
        }
        return result
    }

    private func databaseURL() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        return files.compactMap { url -> (URL, Int)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)) else { return nil }
            return (url, version)
        }.max { $0.1 < $1.1 }?.0
    }

    private func refreshIndex() {
        let url = directory.appendingPathComponent("session_index.jsonl")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else {
            indexNames.removeAll(); indexModifiedAt = nil; indexSize = nil
            return
        }
        guard size != indexSize || modified != indexModifiedAt else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let offset = size > UInt64(Self.indexLimit) ? size - UInt64(Self.indexLimit) : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: Self.indexLimit) ?? Data()
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return }
                data = Data(data[data.index(after: newline)...])
            }
            var names: [String: String] = [:]
            var start = data.startIndex
            for newline in data.indices where data[newline] == 10 {
                let line = Data(data[start..<newline])
                if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                   let id = record["id"] as? String,
                   let text = record["thread_name"] as? String,
                   let name = Self.displayName(text) {
                    names[id] = name // Appended rename records replace older ones.
                }
                start = data.index(after: newline)
            }
            indexNames = names; indexModifiedAt = modified; indexSize = size
        } catch { /* Keep the last valid index during a transient replacement. */ }
    }

    private static func displayName(_ text: String) -> String? {
        let name = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }
}
