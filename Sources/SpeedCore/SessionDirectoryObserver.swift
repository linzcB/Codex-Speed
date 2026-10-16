import Foundation
import CoreServices

public struct SessionDirectoryChange: Sendable {
    public var requiresDiscovery: Bool
    public var modifiedLogs: Set<String> = []
}

/// Watches only for changes relevant to session statistics. The event context
/// owns its handler independently of the stream wrapper, so queued callbacks
/// remain safe when a user changes folders or the observer is deallocated.
public final class SessionDirectoryObserver {
    private var stream: FSEventStreamRef?
    public var isWatching: Bool { stream != nil }

    final class Handler {
        let sessions: String
        let home: String
        let archive: String?
        let receive: (SessionDirectoryChange) -> Void
        init(directory: URL, receive: @escaping (SessionDirectoryChange) -> Void) {
            sessions = directory.resolvingSymlinksInPath().path
            home = directory.deletingLastPathComponent().resolvingSymlinksInPath().path
            archive = directory.lastPathComponent == "sessions" ? home + "/archived_sessions" : nil
            self.receive = receive
        }
        func change(path: String, flags: FSEventStreamEventFlags) -> SessionDirectoryChange? {
            let recovery = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            if flags & UInt32(recovery) != 0 { return SessionDirectoryChange(requiresDiscovery: true) }
            let isLog = path == sessions || path.hasPrefix(sessions + "/")
                || archive.map { path == $0 || path.hasPrefix($0 + "/") } == true
            let name = URL(fileURLWithPath: path).lastPathComponent
            let isTitle = URL(fileURLWithPath: path).deletingLastPathComponent().path == home
                && (name == "session_index.jsonl" || (name.hasPrefix("state_")
                    && (name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal"))))
            guard isLog || isTitle else { return nil }
            // Ignore SQLite -shm: readers can touch it themselves. Authentication
            // files and unrelated Codex home contents are never inspected.
            let structural = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
            return SessionDirectoryChange(requiresDiscovery: isLog && flags & UInt32(structural) != 0,
                modifiedLogs: isLog && path.hasSuffix(".jsonl") ? [path] : [])
        }
    }

    public init(directory: URL, receive: @escaping (SessionDirectoryChange) -> Void) {
        let handler = Handler(directory: directory, receive: receive)
        var root = directory.deletingLastPathComponent().resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: root.path), root.path != "/" {
            root.deleteLastPathComponent()
        }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(info).retain(); return info
            }, release: { info in
                if let info { Unmanaged<Handler>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
        guard let created = FSEventStreamCreate(nil, { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            var change: SessionDirectoryChange?
            for i in 0..<count {
                if let event = handler.change(path: paths[i], flags: eventFlags[i]) {
                    change = SessionDirectoryChange(requiresDiscovery: (change?.requiresDiscovery ?? false) || event.requiresDiscovery,
                        modifiedLogs: (change?.modifiedLogs ?? []).union(event.modifiedLogs))
                }
            }
            if let change { handler.receive(change) }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "local.codexspeed.file-events", qos: .utility))
        if FSEventStreamStart(created) { stream = created }
        else { FSEventStreamInvalidate(created); FSEventStreamRelease(created) }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
