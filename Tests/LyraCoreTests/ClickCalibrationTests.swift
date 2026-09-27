import XCTest
@testable import LyraCore

/// The click-driven capture.
///
/// The contract worth pinning is what a click is allowed to teach the model. A click
/// records where the user was looking, so a click that was plainly at something else,
/// or that has no eye measurement behind it, must be dropped rather than turned into a
/// labelled example — a wrong label is worse than a missing one, because the fit has no
/// way to tell it apart from a right one.
final class ClickCalibrationTests: XCTestCase {

    private let screen = LyraSize(width: 1470, height: 956)

    private func features(pupilX: Double, pupilY: Double = 0.5) -> GazeFeatures {
        GazeFeatures(
            pupilX: pupilX, pupilY: pupilY,
            yaw: 0.01, pitch: 0.02, roll: 0.0,
            faceX: 0.5, faceY: 0.5,
            iod: 0.31, faceWidth: 0.24,
            eyeOpenness: 0.9, confidence: 0.95
        )
    }

    private func makeCapture(
        clicksPerPoint: Int = 4,
        frameBufferLimit: Int = 20,
        minimumFrames: Int = 5
    ) -> ClickCalibration {
        ClickCalibration(
            pattern: .click,
            clicksPerPoint: clicksPerPoint,
            frameBufferLimit: frameBufferLimit,
            minimumFrames: minimumFrames
        )
    }

    /// Fills the buffer with steady frames, then clicks the current dot.
    @discardableResult
    private func clickCurrentDot(
        _ capture: ClickCalibration,
        pupilX: Double = 0.5,
        frames: Int = 10
    ) -> Bool {
        for _ in 0..<frames { capture.observe(features: features(pupilX: pupilX)) }
        let dot = capture.currentPoint!
        return capture.registerClick(atNormalized: (dot.x, dot.y), screenSize: screen)
    }

    // MARK: - Labelling

    func testAClickOnTheDotRecordsASampleLabelledWithThatDot() {
        let capture = makeCapture()
        capture.start()
        XCTAssertTrue(clickCurrentDot(capture, pupilX: 0.42))

        XCTAssertEqual(capture.samples.count, 1)
        let dot = CalibrationPattern.click.points[0]
        XCTAssertEqual(capture.samples[0].targetX, dot.x)
        XCTAssertEqual(capture.samples[0].targetY, dot.y)
        XCTAssertEqual(capture.samples[0].features[0], 0.42, accuracy: 1e-9)
    }

    func testTheDotAdvancesOnlyAfterEnoughClicks() {
        let capture = makeCapture(clicksPerPoint: 3)
        capture.start()

        clickCurrentDot(capture)
        XCTAssertEqual(capture.currentPoint?.id, 0, "advanced after one of three clicks")
        clickCurrentDot(capture)
        XCTAssertEqual(capture.currentPoint?.id, 0, "advanced after two of three clicks")
        clickCurrentDot(capture)
        XCTAssertEqual(capture.currentPoint?.id, 1, "did not advance after the third click")
        XCTAssertEqual(capture.samples.count, 3)
    }

    func testARunProducesOneSamplePerClickAndFinishes() {
        let capture = makeCapture(clicksPerPoint: 4)
        capture.start()

        var guardRail = 0
        while !capture.isFinished, guardRail < 1000 {
            clickCurrentDot(capture)
            guardRail += 1
        }

        XCTAssertTrue(capture.isFinished)
        XCTAssertEqual(capture.samples.count, capture.totalPoints * capture.clicksPerPoint)
        XCTAssertEqual(capture.samples.count, 64)
    }

    // MARK: - Rejection

    func testAClickAwayFromTheDotIsNotRecorded() {
        let capture = makeCapture()
        capture.start()
        for _ in 0..<10 { capture.observe(features: features(pupilX: 0.5)) }

        // The top-left dot is around (0.08, 0.08); clicking the far corner is not a label
        // for it, and letting it through would teach the model that this eye position
        // means the opposite corner of the screen.
        XCTAssertFalse(capture.registerClick(atNormalized: (0.95, 0.95), screenSize: screen))
        XCTAssertTrue(capture.samples.isEmpty)
        XCTAssertEqual(capture.rejectedClicks, 1)
        XCTAssertEqual(capture.currentPoint?.id, 0, "a rejected click must not advance the run")
    }

    func testAClickWithNoEyeMeasurementBehindItIsDropped() {
        let capture = makeCapture(minimumFrames: 5)
        capture.start()
        // Two frames is not enough to average, so there is nothing to label with.
        for _ in 0..<2 { capture.observe(features: features(pupilX: 0.5)) }

        XCTAssertFalse(clickCurrentDot(capture, frames: 0))
        XCTAssertTrue(capture.samples.isEmpty)
        XCTAssertEqual(capture.droppedClicks, 1)
        XCTAssertEqual(capture.currentPoint?.id, 0)
    }

    func testBlinkedFramesDoNotCountTowardsAClick() {
        let capture = makeCapture(minimumFrames: 5)
        capture.start()
        for _ in 0..<12 {
            capture.observe(features: GazeFeatures(
                pupilX: 0.5, pupilY: 0.5, yaw: 0, pitch: 0, roll: 0,
                faceX: 0.5, faceY: 0.5, iod: 0.31, faceWidth: 0.24,
                eyeOpenness: 0.05, confidence: 0.95
            ))
        }
        XCTAssertFalse(clickCurrentDot(capture, frames: 0))
        XCTAssertTrue(capture.samples.isEmpty)
    }

    // MARK: - The label is the eye at the click, not before it

    func testAClickIsLabelledWithTheRecentEyeAndNotTheWholeSession() {
        // The stare-based capture's recurring failure was fitting labels to frames from
        // before the user had arrived. The buffer is what stops the click version doing
        // the same: only the frames immediately behind the click may contribute.
        let capture = makeCapture(frameBufferLimit: 4, minimumFrames: 2)
        capture.start()

        for _ in 0..<20 { capture.observe(features: features(pupilX: 0.2)) }
        for _ in 0..<4 { capture.observe(features: features(pupilX: 0.8)) }

        clickCurrentDot(capture, frames: 0)
        XCTAssertEqual(capture.samples.count, 1)
        XCTAssertEqual(
            capture.samples[0].features[0], 0.8, accuracy: 1e-9,
            "the sample must come from the frames at the click, not from the start of the run"
        )
    }

    func testTheBufferIsClearedWhenTheDotMoves() {
        let capture = makeCapture(clicksPerPoint: 1, frameBufferLimit: 20, minimumFrames: 2)
        capture.start()

        clickCurrentDot(capture, pupilX: 0.7)
        XCTAssertEqual(capture.samples.count, 1)

        // The next dot has no frames behind it yet, so a click there has nothing to label
        // with — rather than reusing the previous dot's eye position.
        let next = capture.currentPoint!
        XCTAssertFalse(capture.registerClick(atNormalized: (next.x, next.y), screenSize: screen))
        XCTAssertEqual(capture.droppedClicks, 1)
        XCTAssertEqual(capture.samples.count, 1)
    }
}
