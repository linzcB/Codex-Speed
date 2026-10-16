import XCTest
import CoreGraphics
@testable import SpeedCore

final class ScreenPlacementTests: XCTestCase {
    func testDropdownRemainsBelowMenuBar() {
        let visible = CGRect(x: 0, y: 38, width: 1512, height: 918)
        let anchor = CGRect(x: 1200, y: 960, width: 104, height: 22)
        let frame = ScreenPlacement.dropdown(anchor: anchor, visible: visible, size: CGSize(width: 360, height: 620))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertLessThan(frame.maxY, anchor.minY)
        XCTAssertEqual(frame.width, 360)
        XCTAssertEqual(frame.height, 620)
    }
    func testSecondaryDisplayWithNegativeOrigin() {
        let visible = CGRect(x: -1920, y: 1080, width: 1920, height: 1056)
        let anchor = CGRect(x: -110, y: 2140, width: 104, height: 22)
        let frame = ScreenPlacement.dropdown(anchor: anchor, visible: visible, size: CGSize(width: 360, height: 620))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertLessThan(frame.maxX, 0)
        XCTAssertGreaterThan(frame.minY, 1080)
        XCTAssertLessThan(frame.maxY, anchor.minY)
    }
    func testSmallScreenFitsEvenWithTallContent() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 480)
        let frame = ScreenPlacement.dropdown(anchor: CGRect(x: 720, y: 480, width: 80, height: 24),
            visible: visible, size: CGSize(width: 360, height: 10000))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.height, 464)
        XCTAssertGreaterThan(frame.minY, visible.minY)
    }
    func testStatusItemWithUnfinishedLaunchCoordinatesDoesNotCollapseWindow() {
        let visible = CGRect(x: 0, y: 38, width: 1512, height: 918)
        let frame = ScreenPlacement.dropdown(anchor: CGRect(x: 0, y: 0, width: 104, height: 22),
            visible: visible, size: CGSize(width: 360, height: 620))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.height, 620)
        XCTAssertEqual(frame.maxY, 948)
    }
    func testBothHorizontalEdgesAreClamped() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for x in [0.0, 1190.0] {
            let frame = ScreenPlacement.dropdown(anchor: CGRect(x: x, y: 800, width: 10, height: 20),
                visible: visible, size: CGSize(width: 360, height: 620))
            XCTAssertTrue(visible.contains(frame))
            XCTAssertGreaterThanOrEqual(frame.minX, 8)
            XCTAssertLessThanOrEqual(frame.maxX, 1192)
        }
    }
    func testPinnedWindowIsRecoveredAfterScreenChange() {
        let visible = CGRect(x: 0, y: 40, width: 1000, height: 600)
        let oversized = CGRect(x: -400, y: 800, width: 360, height: 900)
        let corrected = ScreenPlacement.constrained(oversized, to: visible)
        XCTAssertTrue(visible.contains(corrected))
        XCTAssertEqual(corrected.width, 360)
        XCTAssertEqual(corrected.height, 584)
        XCTAssertEqual(corrected.minX, 8)
    }
}
