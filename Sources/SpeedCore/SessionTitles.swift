import Foundation
import SQLite3

/// Reuses display names while the database and WAL are unchanged. All database
/// access remains read-only; committed WAL renames invalidate the cache.
final class SessionTitles {
    let directory: URL
    private var indexNames: [String: String] = [:]
    private var indexModifiedAt: Date?
    private var indexSize: UInt64?
    private static let indexLimit = 8 * 1024 * 1024
    private var homeSignature: FileSignature?
    private var databaseLocation: URL?
    private var cachedDatabase: DatabaseSignature?
    private var cachedIDs = Set<String>()
    private var databaseNames: [String: String] = [:]

    private struct FileSignature: Equatable {
        var modified: Date?
        var size: UInt64?
        var inode: UInt64?
        init?(_ url: URL) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            modified = attrs[.modificationDate] as? Date
            size = (attrs[.size] as? NSNumber)?.uint64Value
            inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }
    private struct DatabaseSignature: Equatable {
        var url: URL
        var database: FileSignature?
        var wal: FileSignature?
    }

    init(directory: URL) { self.directory = directory }

    func names(for ids: [String]) -> [String: String] {
        refreshIndex()
        let requested = Set(ids)
        var result = Dictionary(uniqueKeysWithValues: requested.compactMap { id in indexNames[id].map { (id, $0) } })
        guard !ids.isEmpty, let url = databaseURL() else { return result }
        let signature = DatabaseSignature(url: url, database: FileSignature(url),
            wal: FileSignature(URL(fileURLWithPath: url.path + "-wal")))
        if signature == cachedDatabase, requested == cachedIDs {
            return result.merging(databaseNames) { _, name in name }
        }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return result
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)
        var statement: OpaquePointer?
        // `title` may contain a raw prompt. Only `name` is a display title.
        let prepared = sqlite3_prepare_v2(database, "SELECT name FROM threads WHERE id = ?", -1,
                                         &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        var names: [String: String] = [:]
        var complete = prepared == SQLITE_OK || prepared == SQLITE_ERROR
        if prepared == SQLITE_OK {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for id in requested {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
                let status = sqlite3_step(statement)
                if status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0),
                   let name = Self.displayName(String(cString: bytes)) { names[id] = name }
                if status != SQLITE_ROW && status != SQLITE_DONE { complete = false }
            }
        }
        // Do not cache transient locks/errors or a database that changed during
        // this read; the next scan must retry instead of hiding a rename.
        let after = DatabaseSignature(url: url, database: FileSignature(url),
            wal: FileSignature(URL(fileURLWithPath: url.path + "-wal")))
        if complete && signature == after {
            cachedDatabase = after; cachedIDs = requested; databaseNames = names
        } else { cachedDatabase = nil }
        result.merge(names) { _, name in name }
        return result
    }

    private func databaseURL() -> URL? {
        let signature = FileSignature(directory)
        if signature == homeSignature, homeSignature != nil { return databaseLocation }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            homeSignature = nil; databaseLocation = nil; return nil
        }
        databaseLocation = files.compactMap { url -> (URL, Int)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)) else { return nil }
            return (url, version)
        }.max { $0.1 < $1.1 }?.0
        homeSignature = signature
        return databaseLocation
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
