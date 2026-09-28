import XCTest
@testable import LyraCore

final class ContextualRegionResolverTests: XCTestCase {

    private let screenSize = LyraSize(width: 1512, height: 982)
    private let resolver = ContextualRegionResolver()

    func testWholeTopRightHighlight() {
        let highlight = resolver.resolve(
            gazePoint: LyraPoint(x: 1350, y: 15),
            screenSize: screenSize
        )

        XCTAssertNotNil(highlight)
        XCTAssertEqual(highlight?.kind, .topRightStatus)
        XCTAssertEqual(highlight?.title, "Control Center & Status")
        XCTAssertGreaterThan(highlight?.frame.width ?? 0, 500.0)
    }

    func testWholeTopLeftHighlight() {
        let highlight = resolver.resolve(
            gazePoint: LyraPoint(x: 120, y: 18),
            screenSize: screenSize
        )

        XCTAssertNotNil(highlight)
        XCTAssertEqual(highlight?.kind, .topLeftMenu)
        XCTAssertEqual(highlight?.title, "Apple & App Menu")
        XCTAssertGreaterThan(highlight?.frame.width ?? 0, 500.0)
    }

    func testWholeDockHighlight() {
        let highlight = resolver.resolve(
            gazePoint: LyraPoint(x: 756, y: 940),
            screenSize: screenSize
        )

        XCTAssertNotNil(highlight)
        XCTAssertEqual(highlight?.kind, .dock)
        XCTAssertEqual(highlight?.title, "Dock")
        XCTAssertGreaterThan(highlight?.frame.width ?? 0, 1000.0)
    }

    func testStageManagerWindowSlotClosestCalculation() {
        // Gaze is at left edge, top-most slot (y ~ 220)
        let slot1 = resolver.resolve(
            gazePoint: LyraPoint(x: 40, y: 220),
            screenSize: screenSize
        )
        XCTAssertNotNil(slot1)
        XCTAssertEqual(slot1?.kind, .stageManager)
        XCTAssertEqual(slot1?.title, "Stage Manager (Window 1)")

        // Gaze is at left edge, bottom-most slot (y ~ 800)
        let slot4 = resolver.resolve(
            gazePoint: LyraPoint(x: 40, y: 800),
            screenSize: screenSize
        )
        XCTAssertNotNil(slot4)
        XCTAssertEqual(slot4?.kind, .stageManager)
        XCTAssertEqual(slot4?.title, "Stage Manager (Window 4)")
    }

    func testScreenCenterReturnsActiveAppWindow() {
        let highlight = resolver.resolve(
            gazePoint: LyraPoint(x: 756, y: 491),
            screenSize: screenSize
        )

        XCTAssertNotNil(highlight)
        XCTAssertEqual(highlight?.kind, .activeAppWindow)
        XCTAssertEqual(highlight?.title, "Active Application")
    }
}
