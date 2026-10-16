import XCTest
import CoreServices
@testable import SpeedCore

final class RefreshPolicyTests: XCTestCase {
    func testOnlyObservedHiddenIdleMonitoringUsesSlowPolling() {
        XCTAssertEqual(RefreshPolicy.interval(isActive: false, isVisible: false, isObserving: true), 30)
        for active in [false, true] {
            for visible in [false, true] {
                XCTAssertEqual(RefreshPolicy.interval(isActive: active, isVisible: visible, isObserving: false), 1)
                if active || visible {
                    XCTAssertEqual(RefreshPolicy.interval(isActive: active, isVisible: visible, isObserving: true), 1)
                }
            }
        }
        XCTAssertEqual(RefreshPolicy.discoveryInterval(isObserving: true), 60)
        XCTAssertEqual(RefreshPolicy.discoveryInterval(isObserving: false), 10)
    }

    func testLogCreationAndRecoveryRequestDiscoveryButAppendsDoNot() {
        let folder = URL(fileURLWithPath: "/tmp/demo-home/sessions")
        let handler = SessionDirectoryObserver.Handler(directory: folder, receive: { _ in })
        let path = handler.sessions + "/2026/10/16/demo.jsonl"
        XCTAssertEqual(handler.change(path: path, flags: UInt32(kFSEventStreamEventFlagItemCreated))?.requiresDiscovery, true)
        XCTAssertEqual(handler.change(path: path, flags: UInt32(kFSEventStreamEventFlagItemRenamed))?.requiresDiscovery, true)
        XCTAssertEqual(handler.change(path: path, flags: UInt32(kFSEventStreamEventFlagItemModified))?.requiresDiscovery, false)
        XCTAssertEqual(handler.change(path: path, flags: UInt32(kFSEventStreamEventFlagItemModified))?.modifiedLogs, [path])
        XCTAssertEqual(handler.change(path: handler.home, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))?.requiresDiscovery, true)
        XCTAssertEqual(handler.change(path: handler.archive! + "/old.jsonl", flags: UInt32(kFSEventStreamEventFlagItemRemoved))?.requiresDiscovery, true)
    }

    func testOnlyRelevantHomeFilesWakeTheMonitor() {
        let handler = SessionDirectoryObserver.Handler(directory: URL(fileURLWithPath: "/tmp/demo-home/sessions"), receive: { _ in })
        let flags = UInt32(kFSEventStreamEventFlagItemModified)
        for name in ["session_index.jsonl", "state_5.sqlite", "state_5.sqlite-wal"] {
            XCTAssertNotNil(handler.change(path: handler.home + "/" + name, flags: flags))
        }
        for path in ["auth.json", "config.toml", "state_5.sqlite-shm", "sessions-other/chat.jsonl", "cache/state_5.sqlite"] {
            XCTAssertNil(handler.change(path: handler.home + "/" + path, flags: flags))
        }
    }
}
