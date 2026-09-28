import XCTest
@testable import LyraCore

final class AdaptiveCalibrationTests: XCTestCase {

    func testAdaptiveCalibrationFullPipeline() throws {
        let calibration = AdaptiveCalibration(
            screenWidth: 1440.0,
            screenHeight: 900.0,
            refinementThresholdPixels: 75.0,
            pursuitDuration: 10.0,
            requireClick: false
        )
        let baseDate = Date()
        calibration.start(at: baseDate)

        var currentTime = baseDate

        // MARK: - Stage 1: Walk through Anchor points until transition to pursuit
        var anchorSteps = 0
        while calibration.progress(at: currentTime).stage == .anchors && anchorSteps < 200 {
            anchorSteps += 1
            let prog = calibration.progress(at: currentTime)
            let targetX = prog.pointX
            let targetY = prog.pointY

            currentTime = currentTime.addingTimeInterval(1.0 / 30.0)
            let feat = GazeFeatures(
                pupilX: 0.5 + 0.30 * (targetX - 0.5),
                pupilY: 0.5 + 0.28 * (targetY - 0.5),
                yaw: 0.001, pitch: 0.0, roll: 0.0,
                faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
            )
            calibration.observe(features: feat, at: currentTime)
        }

        // After anchors, stage should be pursuit
        var prog = calibration.progress(at: currentTime)
        XCTAssertEqual(prog.stage, .pursuit)

        // MARK: - Stage 2: Simulate Pursuit until completion
        let fps = 30.0
        var pursuitSteps = 0
        while calibration.progress(at: currentTime).stage == .pursuit && pursuitSteps < 500 {
            pursuitSteps += 1
            currentTime = currentTime.addingTimeInterval(1.0 / fps)
            let currentProg = calibration.progress(at: currentTime)
            let feat = GazeFeatures(
                pupilX: 0.5 + 0.30 * (currentProg.pointX - 0.5),
                pupilY: 0.5 + 0.28 * (currentProg.pointY - 0.5),
                yaw: 0.001, pitch: 0.0, roll: 0.0,
                faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
            )
            calibration.observe(features: feat, at: currentTime)
        }

        // MARK: - Verify completion & accuracy
        prog = calibration.progress(at: currentTime)
        // Since ground truth has zero noise, Stage 3 should be skipped or completed
        XCTAssertTrue(prog.stage == .finished || prog.stage == .refinement)

        if prog.stage == .refinement {
            // Provide clean frames for refinement
            for _ in 0..<10 {
                currentTime = currentTime.addingTimeInterval(1.0 / 30.0)
                let refProg = calibration.progress(at: currentTime)
                let feat = GazeFeatures(
                    pupilX: 0.5 + 0.30 * (refProg.pointX - 0.5),
                    pupilY: 0.5 + 0.28 * (refProg.pointY - 0.5),
                    yaw: 0.0, pitch: 0.0, roll: 0.0,
                    faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                    eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
                )
                calibration.observe(features: feat, at: currentTime)
            }
            prog = calibration.progress(at: currentTime)
            XCTAssertEqual(prog.stage, .finished)
        }

        XCTAssertNotNil(calibration.finalMap)
        if let map = calibration.finalMap {
            XCTAssertTrue(map.isCalibrated)
            XCTAssertLessThan(map.validationErrorPixels, 60.0, "Adaptive calibration should achieve < 60 px error")
        }
    }

    func testAdaptiveCalibrationClickDrivenPipeline() throws {
        let calibration = AdaptiveCalibration(
            screenWidth: 1440.0,
            screenHeight: 900.0,
            refinementThresholdPixels: 75.0,
            pursuitDuration: 6.0,
            requireClick: true
        )
        let baseDate = Date()
        calibration.start(at: baseDate)
        var currentTime = baseDate

        // Stage 1: Static corners are clicked
        for i in 0..<5 {
            let prog = calibration.progress(at: currentTime)
            XCTAssertEqual(prog.stage, .anchors)
            XCTAssertEqual(prog.currentPointIndex, i + 1)

            // Buffer 4 usable frames
            for _ in 0..<4 {
                currentTime = currentTime.addingTimeInterval(1.0 / 30.0)
                let feat = GazeFeatures(
                    pupilX: 0.5 + 0.30 * (prog.pointX - 0.5),
                    pupilY: 0.5 + 0.28 * (prog.pointY - 0.5),
                    yaw: 0.0, pitch: 0.0, roll: 0.0,
                    faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                    eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
                )
                calibration.observe(features: feat, at: currentTime)
            }

            let clicked = calibration.registerClick(at: currentTime)
            XCTAssertTrue(clicked, "Click should advance anchor point")
        }

        // Transitions to pursuit
        var prog = calibration.progress(at: currentTime)
        XCTAssertEqual(prog.stage, .pursuit)

        // Stage 2: Super-slow pursuit
        let fps = 30.0
        var pursuitSteps = 0
        while calibration.progress(at: currentTime).stage == .pursuit && pursuitSteps < 300 {
            pursuitSteps += 1
            currentTime = currentTime.addingTimeInterval(1.0 / fps)
            let currentProg = calibration.progress(at: currentTime)
            let feat = GazeFeatures(
                pupilX: 0.5 + 0.30 * (currentProg.pointX - 0.5),
                pupilY: 0.5 + 0.28 * (currentProg.pointY - 0.5),
                yaw: 0.001, pitch: 0.0, roll: 0.0,
                faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
            )
            calibration.observe(features: feat, at: currentTime)
        }

        // Stage 3 or Finished
        prog = calibration.progress(at: currentTime)
        if prog.stage == .refinement {
            while calibration.progress(at: currentTime).stage == .refinement {
                let refProg = calibration.progress(at: currentTime)
                for _ in 0..<4 {
                    currentTime = currentTime.addingTimeInterval(1.0 / 30.0)
                    let feat = GazeFeatures(
                        pupilX: 0.5 + 0.30 * (refProg.pointX - 0.5),
                        pupilY: 0.5 + 0.28 * (refProg.pointY - 0.5),
                        yaw: 0.0, pitch: 0.0, roll: 0.0,
                        faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                        eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
                    )
                    calibration.observe(features: feat, at: currentTime)
                }
                let clicked = calibration.registerClick(at: currentTime)
                XCTAssertTrue(clicked)
            }
        }

        prog = calibration.progress(at: currentTime)
        XCTAssertEqual(prog.stage, .finished)
        XCTAssertNotNil(calibration.finalMap)
        XCTAssertTrue(calibration.finalMap!.isCalibrated)
    }

    func testRefinementTriggersOnHighErrorPointAndRecalibrates() throws {
        let calibration = AdaptiveCalibration(
            screenWidth: 1440.0,
            screenHeight: 900.0,
            refinementThresholdPixels: 50.0, // Low threshold to force refinement on corrupted region
            pursuitDuration: 10.0,
            requireClick: false
        )
        let baseDate = Date()
        calibration.start(at: baseDate)
        var currentTime = baseDate

        // Stage 1: Anchors
        var anchorSteps = 0
        while calibration.progress(at: currentTime).stage == .anchors && anchorSteps < 200 {
            anchorSteps += 1
            let prog = calibration.progress(at: currentTime)
            currentTime = currentTime.addingTimeInterval(1.0 / 30.0)
            let feat = GazeFeatures(
                pupilX: 0.5 + 0.30 * (prog.pointX - 0.5),
                pupilY: 0.5 + 0.28 * (prog.pointY - 0.5),
                yaw: 0.0, pitch: 0.0, roll: 0.0,
                faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
            )
            calibration.observe(features: feat, at: currentTime)
        }

        // Stage 2: Pursuit with one corrupted region (near top-left)
        let fps = 30.0
        var pursuitSteps = 0
        while calibration.progress(at: currentTime).stage == .pursuit && pursuitSteps < 500 {
            pursuitSteps += 1
            currentTime = currentTime.addingTimeInterval(1.0 / fps)
            let currentProg = calibration.progress(at: currentTime)
            var px = 0.5 + 0.30 * (currentProg.pointX - 0.5)
            var py = 0.5 + 0.28 * (currentProg.pointY - 0.5)

            // Inject large error when target is in top-left
            if currentProg.pointX < 0.25 && currentProg.pointY < 0.25 {
                px += 0.15 // large artificial squint/outlier
            }

            let feat = GazeFeatures(
                pupilX: px, pupilY: py,
                yaw: 0.0, pitch: 0.0, roll: 0.0,
                faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
            )
            calibration.observe(features: feat, at: currentTime)
        }

        // Stage 3: Must enter refinement for the corrupted region
        var prog = calibration.progress(at: currentTime)
        XCTAssertEqual(prog.stage, .refinement, "High-error region should trigger Stage 3 refinement")

        // Satisfy refinement with clean, true features
        var refSteps = 0
        while calibration.progress(at: currentTime).stage == .refinement && refSteps < 100 {
            refSteps += 1
            currentTime = currentTime.addingTimeInterval(1.0 / 30.0)
            let refProg = calibration.progress(at: currentTime)
            let feat = GazeFeatures(
                pupilX: 0.5 + 0.30 * (refProg.pointX - 0.5),
                pupilY: 0.5 + 0.28 * (refProg.pointY - 0.5),
                yaw: 0.0, pitch: 0.0, roll: 0.0,
                faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                eyeOpenness: 0.9, confidence: 1.0, timestamp: currentTime
            )
            calibration.observe(features: feat, at: currentTime)
        }

        prog = calibration.progress(at: currentTime)
        XCTAssertEqual(prog.stage, .finished)
        XCTAssertNotNil(calibration.finalMap)
    }
}
