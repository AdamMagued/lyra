import XCTest
@testable import LyraCore

/// The pieces between "camera produced a number" and "a thing on screen got clicked".
/// All of it is pure, which is the point: the maths that decides what the user meant is
/// testable without a camera, a screen, or a face.
final class TargetingTests: XCTestCase {

    // MARK: - Helpers

    private func candidate(
        _ id: String,
        _ x: Double, _ y: Double, _ w: Double, _ h: Double,
        actionable: Bool = true,
        depth: Int = 3
    ) -> TargetCandidate {
        TargetCandidate(
            id: id,
            frame: LyraRect(x: x, y: y, width: w, height: h),
            label: id,
            role: "AXButton",
            source: .accessibility,
            depth: depth,
            isActionable: actionable,
            action: actionable ? .press : nil
        )
    }

    private let screen = LyraSize(width: 1512, height: 982)

    // MARK: - Resolver

    func testInsideTargetWinsOverNearbyLargerOne() {
        let resolver = TargetResolver()
        let small = candidate("small", 100, 100, 40, 24)
        let large = candidate("large", 60, 60, 300, 300)

        let selection = resolver.resolve(
            gazePoint: LyraPoint(x: 120, y: 112),
            candidates: [large, small],
            screenSize: screen,
            gazeConfidence: 0.9
        )

        // The small button is *inside* the gaze point; the large container merely
        // contains it. Aiming at a button and getting the panel it sits on is the
        // single most annoying failure of a naive nearest-target resolver.
        XCTAssertEqual(selection?.candidate.id, "small")
    }

    func testContainingBeatsNearestEvenWhenFarAway() {
        let resolver = TargetResolver()
        let inside = candidate("inside", 200, 400, 100, 40)
        let closer = candidate("closer", 310, 400, 30, 30)

        let selection = resolver.resolve(
            gazePoint: LyraPoint(x: 250, y: 420),
            candidates: [inside, closer],
            screenSize: screen,
            gazeConfidence: 0.9
        )

        XCTAssertEqual(selection?.candidate.id, "inside")
    }

    func testNonActionableContainerIsReportedButNotClickable() {
        let resolver = TargetResolver()
        let container = candidate("panel", 0, 0, 400, 400, actionable: false)

        let selection = resolver.resolve(
            gazePoint: LyraPoint(x: 200, y: 200),
            candidates: [container],
            screenSize: screen,
            gazeConfidence: 1.0
        )

        // Reported on purpose — "you are looking at the sidebar" is more useful than
        // silence. The contract is that it is never *actionable*, which the coordinator
        // enforces before anything reaches the input layer.
        XCTAssertEqual(selection?.candidate.id, "panel")
        XCTAssertFalse(selection?.candidate.isActionable ?? true)
    }

    func testActionableTargetWinsAgainstANonActionableOneAtTheSameDistance() {
        let resolver = TargetResolver()
        let label = candidate("label", 100, 100, 80, 20, actionable: false)
        let button = candidate("button", 100, 122, 80, 20)

        let selection = resolver.resolve(
            gazePoint: LyraPoint(x: 140, y: 110),
            candidates: [label, button],
            screenSize: screen,
            gazeConfidence: 0.9
        )

        XCTAssertEqual(selection?.candidate.id, "button")
    }

    func testSnapRadiusIsRespected() {
        let resolver = TargetResolver(snapRadius: 70)
        let far = candidate("far", 900, 900, 40, 40)

        XCTAssertNil(resolver.resolve(
            gazePoint: LyraPoint(x: 100, y: 100),
            candidates: [far],
            screenSize: screen,
            gazeConfidence: 1.0
        ))

        let near = candidate("near", 130, 100, 40, 40)
        XCTAssertEqual(
            resolver.resolve(
                gazePoint: LyraPoint(x: 100, y: 100),
                candidates: [near],
                screenSize: screen,
                gazeConfidence: 1.0
            )?.candidate.id,
            "near"
        )
    }

    // MARK: - Stabilizer

    func testDwellCommitsOnlyAfterTheDuration() {
        var stabilizer = TargetStabilizer(dwellDuration: 0.5)
        let selection = TargetSelection(
            candidate: candidate("a", 0, 0, 50, 50),
            distance: 0,
            confidence: 0.9
        )

        XCTAssertEqual(stabilizer.update(selection: selection, at: 10.0), .pending(selection, progress: 0))

        if case .pending(_, let progress) = stabilizer.update(selection: selection, at: 10.25) {
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)
        } else {
            XCTFail("expected still pending halfway through the dwell")
        }

        guard case .committed(let committed) = stabilizer.update(selection: selection, at: 10.6) else {
            return XCTFail("expected a commit once the dwell elapsed")
        }
        XCTAssertEqual(committed.id, "a")
    }

    func testGlancingAwayResetsProgress() {
        var stabilizer = TargetStabilizer(dwellDuration: 0.5)
        let a = TargetSelection(candidate: candidate("a", 0, 0, 50, 50), distance: 0, confidence: 0.9)
        let b = TargetSelection(candidate: candidate("b", 200, 0, 50, 50), distance: 0, confidence: 0.9)

        _ = stabilizer.update(selection: a, at: 10.0)
        _ = stabilizer.update(selection: a, at: 10.4)

        // Switching targets must restart the clock, not carry the progress over —
        // otherwise two half-glances at two different things commit one of them.
        let switched = stabilizer.update(selection: b, at: 10.45)
        if case .pending(let selection, let progress) = switched {
            XCTAssertEqual(selection.candidate.id, "b")
            XCTAssertEqual(progress, 0, accuracy: 0.05)
        } else {
            XCTFail("expected the switch to reset progress")
        }
    }

    func testWeakConfidenceDoesNotCommit() {
        var stabilizer = TargetStabilizer(dwellDuration: 0.3, minimumConfidence: 0.5)
        let weak = TargetSelection(candidate: candidate("a", 0, 0, 50, 50), distance: 0, confidence: 0.2)

        _ = stabilizer.update(selection: weak, at: 0)
        XCTAssertEqual(stabilizer.update(selection: weak, at: 5.0), .none)
    }

    // MARK: - Lens

    func testLensRowsAreTallerThanTypicalTrackerError() {
        // The entire premise of the lens: a row must be comfortably taller than the
        // ~100 point error of a webcam tracker, or gaze cannot select within it.
        let lens = TargetLens()
        XCTAssertGreaterThan(lens.rowHeight, 100)
        XCTAssertLessThanOrEqual(lens.maximumRows, 6)
    }

    func testLensRanksByDistanceFromGaze() {
        let lens = TargetLens()
        let candidates = [
            candidate("far", 1200, 800, 40, 40),
            candidate("near", 700, 500, 40, 40),
            candidate("mid", 900, 600, 40, 40)
        ]

        let layout = lens.layout(
            candidates: candidates,
            gazePoint: LyraPoint(x: 720, y: 520),
            screenSize: screen
        )

        XCTAssertEqual(layout.entries.map(\.candidate.id), ["near", "mid", "far"])
    }

    func testLensRowsDoNotOverlap() {
        let lens = TargetLens()
        let candidates = (0..<5).map { candidate("c\($0)", 700, 400 + Double($0) * 30, 40, 40) }

        let layout = lens.layout(
            candidates: candidates,
            gazePoint: LyraPoint(x: 720, y: 500),
            screenSize: screen
        )

        for (a, b) in zip(layout.entries, layout.entries.dropFirst()) {
            XCTAssertLessThanOrEqual(a.rowFrame.maxY, b.rowFrame.minY)
        }
    }

    func testBetweenRowsResolvesToTheNearerOne() {
        let lens = TargetLens(rowHeight: 100, rowSpacing: 20)
        let candidates = [
            candidate("top", 700, 400, 40, 40),
            candidate("bottom", 700, 560, 40, 40)
        ]

        let layout = lens.layout(
            candidates: candidates,
            gazePoint: LyraPoint(x: 720, y: 460),
            screenSize: screen
        )

        guard let top = layout.entries.first(where: { $0.candidate.id == "top" }) else {
            return XCTFail("expected a top row")
        }

        // Aim just below the top row, inside the gap, and slightly nearer the bottom.
        let justBelow = LyraPoint(x: top.rowFrame.midX, y: top.rowFrame.maxY + 12)
        XCTAssertEqual(lens.row(at: justBelow, in: layout)?.candidate.id, "bottom")
    }

    func testGazeOffTheLensSelectsNothing() {
        let lens = TargetLens()
        let layout = lens.layout(
            candidates: [candidate("a", 700, 400, 40, 40)],
            gazePoint: LyraPoint(x: 720, y: 420),
            screenSize: screen
        )

        XCTAssertNil(lens.row(at: LyraPoint(x: 40, y: 900), in: layout))
    }

    func testLensPrefersActionableTargetsButFallsBackToContext() {
        let lens = TargetLens()
        let layout = lens.layout(
            candidates: [candidate("label", 700, 400, 60, 20, actionable: false)],
            gazePoint: LyraPoint(x: 720, y: 410),
            screenSize: screen
        )

        // A lone non-actionable element still gets a row: showing "you are looking at
        // the sidebar" beats showing an empty lens.
        XCTAssertEqual(layout.entries.count, 1)
    }

    // MARK: - Risk policy

    func testUndoDoesNotRequireConfirmation() {
        // Undo is the *recovery* path. Making it harder to undo a mistake than to make
        // one is backwards, and a confirmation prompt here just trains the user to say
        // "yes" reflexively to whatever comes next.
        let policy = RiskPolicy()
        XCTAssertFalse(policy.requiresConfirmation(.undo, on: candidate("a", 0, 0, 10, 10)))
    }

    func testOrdinaryClickOnOrdinaryButtonNeedsNoConfirmation() {
        let policy = RiskPolicy()
        XCTAssertFalse(policy.requiresConfirmation(.activate, on: candidate("a", 0, 0, 10, 10)))
    }

    func testDestructiveLabelsRaiseRisk() {
        let policy = RiskPolicy()
        let delete = TargetCandidate(
            id: "delete",
            frame: LyraRect(x: 0, y: 0, width: 80, height: 24),
            label: "Delete file",
            role: "AXButton",
            source: .accessibility,
            depth: 3,
            isActionable: true,
            action: .press
        )
        XCTAssertTrue(policy.requiresConfirmation(.activate, on: delete))
    }
}
