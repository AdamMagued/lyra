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

    func testTopBarEffortlessActivationWithoutCornerStrain() {
        // Looking up into the upper 22% of screen (y=80, well below the menu bar sliver)
        let topLeft = resolver.resolve(
            gazePoint: LyraPoint(x: 350, y: 80),
            screenSize: screenSize
        )
        XCTAssertNotNil(topLeft)
        XCTAssertEqual(topLeft?.kind, .topLeftMenu)
        XCTAssertEqual(topLeft?.title, "Apple & App Menu")

        let topRight = resolver.resolve(
            gazePoint: LyraPoint(x: 1150, y: 80),
            screenSize: screenSize
        )
        XCTAssertNotNil(topRight)
        XCTAssertEqual(topRight?.kind, .topRightStatus)
        XCTAssertEqual(topRight?.title, "Control Center & Status")
    }

    func testDockAccurateLowGazeActivation() {
        // Gaze is at y=750 (bottom 28%), which with normal eyelid downward droop easily triggers Dock
        let highlight = resolver.resolve(
            gazePoint: LyraPoint(x: 756, y: 750),
            screenSize: screenSize
        )
        XCTAssertNotNil(highlight)
        XCTAssertEqual(highlight?.kind, .dock)
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

        // Gaze is at left edge, middle slot (y ~ 610)
        let slot3 = resolver.resolve(
            gazePoint: LyraPoint(x: 40, y: 610),
            screenSize: screenSize
        )
        XCTAssertNotNil(slot3)
        XCTAssertEqual(slot3?.kind, .stageManager)
        XCTAssertEqual(slot3?.title, "Stage Manager (Window 3)")
    }

    func testOpenWindowHighlightingAroundWindowUnderGaze() {
        let safariFrame = LyraRect(x: 200, y: 150, width: 500, height: 450)
        let xcodeFrame = LyraRect(x: 750, y: 150, width: 600, height: 500)

        let candidates = [
            TargetCandidate(
                id: "win-safari",
                frame: safariFrame,
                label: "Safari — GitHub",
                role: "AXWindow",
                source: .screenRegion,
                depth: 1,
                isActionable: true,
                action: .press
            ),
            TargetCandidate(
                id: "win-xcode",
                frame: xcodeFrame,
                label: "Xcode — Lyra",
                role: "AXWindow",
                source: .screenRegion,
                depth: 1,
                isActionable: true,
                action: .press
            )
        ]

        // 1. Looking at Safari window
        let safariHighlight = resolver.resolve(
            gazePoint: LyraPoint(x: 400, y: 300),
            screenSize: screenSize,
            candidates: candidates
        )
        XCTAssertNotNil(safariHighlight)
        XCTAssertEqual(safariHighlight?.kind, .activeAppWindow)
        XCTAssertEqual(safariHighlight?.title, "Safari — GitHub")
        XCTAssertEqual(safariHighlight?.frame, safariFrame)

        // 2. Looking at Xcode window
        let xcodeHighlight = resolver.resolve(
            gazePoint: LyraPoint(x: 950, y: 350),
            screenSize: screenSize,
            candidates: candidates
        )
        XCTAssertNotNil(xcodeHighlight)
        XCTAssertEqual(xcodeHighlight?.kind, .activeAppWindow)
        XCTAssertEqual(xcodeHighlight?.title, "Xcode — Lyra")
        XCTAssertEqual(xcodeHighlight?.frame, xcodeFrame)
    }

    func testScreenCenterFallbackNotTooBig() {
        let highlight = resolver.resolve(
            gazePoint: LyraPoint(x: 756, y: 491),
            screenSize: screenSize
        )

        XCTAssertNotNil(highlight)
        XCTAssertEqual(highlight?.kind, .activeAppWindow)
        XCTAssertEqual(highlight?.title, "Active Application")
        // Verify fallback is well-proportioned, not a screen-filling 90%+ box
        XCTAssertLessThanOrEqual(highlight?.frame.width ?? 0, screenSize.width * 0.65)
        XCTAssertLessThanOrEqual(highlight?.frame.height ?? 0, screenSize.height * 0.60)
    }
}
