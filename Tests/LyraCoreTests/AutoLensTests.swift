import XCTest
@testable import LyraCore

/// The automatic lens. Every case here is a way the feature could become unusable, which
/// matters more than usual: a lens that opens when it should not is worse than no lens,
/// because it takes over the screen at the moment the user was trying to do something.
final class AutoLensTests: XCTestCase {

    private func candidate(
        id: String,
        frame: LyraRect,
        actionable: Bool = true
    ) -> TargetCandidate {
        TargetCandidate(
            id: id,
            frame: frame,
            label: id,
            role: "AXButton",
            source: .accessibility,
            depth: 1,
            isActionable: actionable,
            action: actionable ? .press : nil
        )
    }

    /// Four 20-point toolbar icons in a row, the situation the lens exists for.
    private var toolbar: [TargetCandidate] {
        (0..<4).map { index in
            candidate(
                id: "icon\(index)",
                frame: LyraRect(x: 400 + Double(index) * 26, y: 590, width: 20, height: 20)
            )
        }
    }

    /// Stage Manager thumbnails, measured from a real display: 137 points wide, 167 tall,
    /// stacked with a 8-point gap between them.
    private var strip: [TargetCandidate] {
        [160.0, 335.0, 505.0, 654.0].enumerated().map { index, y in
            candidate(
                id: "thumb\(index)",
                frame: LyraRect(x: 16, y: y, width: 137, height: index == 3 ? 175 : 167)
            )
        }
    }

    private let onTheToolbar = LyraPoint(x: 440, y: 600)

    // MARK: - Trigger

    func testClusterOfSmallControlsIsDetected() {
        let tracker = AutoLensTracker()
        XCTAssertTrue(tracker.isCluster(gazePoint: onTheToolbar, candidates: toolbar, radius: 130))
    }

    func testLargeTargetsDoNotTrigger() {
        // One big button under the gaze is the case gaze already handles. Magnifying it
        // would be pure interruption.
        let big = [
            candidate(id: "a", frame: LyraRect(x: 300, y: 500, width: 400, height: 300)),
            candidate(id: "b", frame: LyraRect(x: 700, y: 500, width: 400, height: 300))
        ]
        let tracker = AutoLensTracker()
        XCTAssertFalse(tracker.isCluster(gazePoint: LyraPoint(x: 400, y: 600), candidates: big, radius: 130))
    }

    func testSingleSmallTargetDoesNotTrigger() {
        // One small control is a precision problem, not an ambiguity. The "look at it and
        // click" path plus "next" already covers it.
        let tracker = AutoLensTracker()
        XCTAssertFalse(
            tracker.isCluster(gazePoint: onTheToolbar, candidates: [toolbar[0]], radius: 130)
        )
    }

    func testDistantTargetsDoNotTrigger() {
        let far = (0..<4).map { index in
            candidate(
                id: "far\(index)",
                frame: LyraRect(x: 2000 + Double(index) * 26, y: 100, width: 20, height: 20)
            )
        }
        let tracker = AutoLensTracker()
        XCTAssertFalse(tracker.isCluster(gazePoint: onTheToolbar, candidates: far, radius: 130))
    }

    func testNonActionableTargetsDoNotTrigger() {
        // A row of labels is not something the lens can resolve — there is nothing to
        // choose between, because none of them can be clicked.
        let labels = toolbar.enumerated().map { index, item in
            candidate(id: "label\(index)", frame: item.frame, actionable: false)
        }
        let tracker = AutoLensTracker()
        XCTAssertFalse(tracker.isCluster(gazePoint: onTheToolbar, candidates: labels, radius: 130))
    }

    // MARK: - The radius comes from the measured error

    func testTheRadiusDecidesWhetherThumbnailsCompete() {
        // This is the whole reason the radius is a parameter rather than a constant. The
        // real thumbnails are 167 points tall with an 8-point gap, so how many of them are
        // in play depends entirely on how badly the tracker misses — which is measured
        // during calibration and differs per person, per camera, per lighting.
        let tracker = AutoLensTracker()
        // In the strip column, above the top thumbnail: close to the first one, well clear
        // of the second.
        let inTheStrip = LyraPoint(x: 80, y: 100)

        // A tracker accurate to 130 points is only really pointing at one thumbnail here.
        XCTAssertFalse(tracker.isCluster(gazePoint: inTheStrip, candidates: strip, radius: 130))
        // At 250 points of error the next thumbnail is inside the same radius, so the gaze
        // no longer says which one was meant and the lens is the only way to resolve it.
        XCTAssertTrue(tracker.isCluster(gazePoint: inTheStrip, candidates: strip, radius: 250))
    }

    func testTheConfiguredRadiusIsAFloor() {
        // A calibration that reports a tiny error must not switch the lens off entirely —
        // the error is a held-out estimate and can be optimistic, so it is never allowed
        // to take the radius below what the policy asks for.
        let tracker = AutoLensTracker(policy: AutoLensPolicy(clusterRadius: 130))
        XCTAssertTrue(tracker.isCluster(gazePoint: onTheToolbar, candidates: toolbar, radius: 5))
    }

    // MARK: - Dwell

    func testLensOpensOnlyAfterTheDwell() {
        var tracker = AutoLensTracker(policy: AutoLensPolicy(dwellToOpen: 0.35))

        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.0))
        // A glance passing across the toolbar must not pop a panel open.
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.2))
        XCTAssertTrue(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.4))
        XCTAssertTrue(tracker.isOpen)
    }

    func testLeavingTheClusterResetsTheDwell() {
        var tracker = AutoLensTracker(policy: AutoLensPolicy(dwellToOpen: 0.35))
        let away = LyraPoint(x: 1200, y: 200)

        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.0)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.3)
        // Looked away just before the dwell elapsed: the clock has to start again, or
        // four separate glances across the toolbar would add up to one deliberate one.
        _ = tracker.updateClosed(gazePoint: away, candidates: toolbar, radius: 130, at: 0.31)
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.5))
        XCTAssertTrue(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.9))
    }

    func testDisabledPolicyNeverOpens() {
        var tracker = AutoLensTracker(policy: AutoLensPolicy(isEnabled: false))
        for step in 0..<20 {
            XCTAssertFalse(
                tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: Double(step) * 0.1)
            )
        }
        XCTAssertFalse(tracker.isOpen)
    }

    // MARK: - Closing

    func testLensStaysOpenWhileTheGazeIsOnIt() {
        var tracker = AutoLensTracker()
        let panel = LyraRect(x: 400, y: 300, width: 700, height: 600)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.0)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 1.0)

        // This is the case the naive "close when the gaze leaves the cluster" rule gets
        // wrong: choosing a row *requires* leaving the cluster.
        for step in 0..<30 {
            XCTAssertFalse(
                tracker.updateOpen(gazePoint: LyraPoint(x: 700, y: 500), lensPanel: panel, at: 1.0 + Double(step) * 0.1)
            )
        }
        XCTAssertTrue(tracker.isOpen)
    }

    func testLensClosesAfterLookingAway() {
        var tracker = AutoLensTracker(policy: AutoLensPolicy(dwellToClose: 1.1))
        let panel = LyraRect(x: 400, y: 300, width: 700, height: 600)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.0)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 1.0)

        let away = LyraPoint(x: 60, y: 1600)
        XCTAssertFalse(tracker.updateOpen(gazePoint: away, lensPanel: panel, at: 2.0))
        XCTAssertTrue(tracker.updateOpen(gazePoint: away, lensPanel: panel, at: 3.2))
        XCTAssertFalse(tracker.isOpen)
    }

    func testNearMissOnThePanelEdgeIsNotLeaving() {
        var tracker = AutoLensTracker(policy: AutoLensPolicy(dwellToClose: 0.5))
        let panel = LyraRect(x: 400, y: 300, width: 700, height: 600)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.0)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 1.0)

        // Aiming at the top row, gaze overshoots the panel edge by a tracker error's
        // worth. Treating that as "looked away" would shut the lens as the user uses it.
        let justAbove = LyraPoint(x: 700, y: 250)
        for step in 0..<20 {
            XCTAssertFalse(
                tracker.updateOpen(gazePoint: justAbove, lensPanel: panel, at: 2.0 + Double(step) * 0.1)
            )
        }
        XCTAssertTrue(tracker.isOpen)
    }

    func testCooldownStopsTheLensSnappingBackOpen() {
        var tracker = AutoLensTracker(policy: AutoLensPolicy(dwellToOpen: 0.2, dwellToClose: 0.5, cooldown: 1.5))
        let panel = LyraRect(x: 400, y: 300, width: 700, height: 600)

        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 0.0)
        _ = tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 1.0)

        let away = LyraPoint(x: 60, y: 1600)
        _ = tracker.updateOpen(gazePoint: away, lensPanel: panel, at: 2.0)
        XCTAssertTrue(tracker.updateOpen(gazePoint: away, lensPanel: panel, at: 2.6))

        // The user's gaze drifts back to where the cluster was. Without the cooldown the
        // lens reopens immediately and they cannot get out of it.
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 3.0))
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 3.5))
        // Past the cooldown, and after a fresh dwell, it may open again.
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 4.6))
        XCTAssertTrue(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 4.9))
    }

    func testExplicitCloseAlsoStartsTheCooldown() {
        // "Hide targets" must not be undone a second later by the gaze that was already
        // sitting on the cluster when the user said it.
        var tracker = AutoLensTracker(policy: AutoLensPolicy(dwellToOpen: 0.2, cooldown: 1.5))
        tracker.close(at: 10.0)
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 10.5))
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 11.0))
        // Past the cooldown, but the dwell still has to be earned from scratch.
        XCTAssertFalse(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 12.0))
        XCTAssertTrue(tracker.updateClosed(gazePoint: onTheToolbar, candidates: toolbar, radius: 130, at: 12.3))
    }
}
