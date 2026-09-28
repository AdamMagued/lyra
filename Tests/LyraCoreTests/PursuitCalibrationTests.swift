import XCTest
@testable import LyraCore

final class PursuitCalibrationTests: XCTestCase {

    func testTrajectoryEndpointsAreCentered() {
        let start = PursuitCalibration.pointOnTrajectory(progress: 0.0)
        XCTAssertEqual(start.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(start.y, 0.5, accuracy: 1e-4)

        let end = PursuitCalibration.pointOnTrajectory(progress: 1.0)
        XCTAssertEqual(end.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(end.y, 0.5, accuracy: 1e-4)
    }

    func testTrajectoryCoversAllGridBins() {
        var visitedBins = Set<Int>()
        let steps = 500
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let pt = PursuitCalibration.pointOnTrajectory(progress: u)
            let col = min(max(Int(pt.x * 5.0), 0), 4)
            let row = min(max(Int(pt.y * 5.0), 0), 4)
            visitedBins.insert(row * 5 + col)
        }

        XCTAssertEqual(visitedBins.count, 25, "Smooth pursuit trajectory must visit every bin in a 5x5 grid")
    }

    func testTrajectoryIsSmoothAndBounded() {
        let steps = 600
        var prev = PursuitCalibration.pointOnTrajectory(progress: 0.0)
        var maxStep = 0.0

        for i in 1...steps {
            let u = Double(i) / Double(steps)
            let pt = PursuitCalibration.pointOnTrajectory(progress: u)
            XCTAssertTrue((0.008...0.992).contains(pt.x))
            XCTAssertTrue((0.008...0.992).contains(pt.y))

            let dist = hypot(pt.x - prev.x, pt.y - prev.y)
            maxStep = max(maxStep, dist)
            prev = pt
        }

        // At 600 steps over 18s (≈ 33 steps/sec), maximum distance per step must be small (< 0.035 screen width)
        XCTAssertLessThan(maxStep, 0.035)
    }

    func testCountdownPhaseIgnoresFramesAndPursuitCaptures() {
        let pursuit = PursuitCalibration(durationSeconds: 10.0, countdownSeconds: 2.0)
        let baseDate = Date()
        pursuit.start(at: baseDate)

        let mockFeature = GazeFeatures(
            pupilX: 0.5, pupilY: 0.5, yaw: 0, pitch: 0, roll: 0,
            faceX: 0.5, faceY: 0.5, iod: 0.1, faceWidth: 0.3,
            eyeOpenness: 0.9, confidence: 1.0, timestamp: baseDate
        )

        // During countdown (t = 1.0s < 2.0s)
        pursuit.observe(features: mockFeature, at: baseDate.addingTimeInterval(1.0))
        var progress = pursuit.progress(at: baseDate.addingTimeInterval(1.0))
        XCTAssertEqual(progress.phase, .countdown)
        XCTAssertEqual(progress.framesCaptured, 0)
        XCTAssertEqual(progress.pointX, 0.5, accuracy: 1e-4)
        XCTAssertEqual(progress.pointY, 0.5, accuracy: 1e-4)

        // During pursuit (t = 3.0s > 2.0s)
        pursuit.observe(features: mockFeature, at: baseDate.addingTimeInterval(3.0))
        progress = pursuit.progress(at: baseDate.addingTimeInterval(3.0))
        XCTAssertEqual(progress.phase, .pursuing)
        XCTAssertEqual(progress.framesCaptured, 1)

        // After completion (t = 13.0s > 12.0s)
        progress = pursuit.progress(at: baseDate.addingTimeInterval(13.0))
        XCTAssertEqual(progress.phase, .finished)
        XCTAssertTrue(progress.isFinished)
    }

    func testFinishBinsFramesAndCalibratesAccurately() throws {
        let pursuit = PursuitCalibration(durationSeconds: 18.0, countdownSeconds: 1.0)
        let baseDate = Date()
        pursuit.start(at: baseDate)

        // Simulate 30 fps camera feed for 18 seconds
        let fps = 30.0
        let totalFrames = Int(18.0 * fps)
        for i in 0..<totalFrames {
            let t = 1.0 + Double(i) / fps
            let date = baseDate.addingTimeInterval(t)
            let target = pursuit.targetPosition(at: date)

            // Ground truth mapping: pupilX = 0.5 + 0.30 * (targetX - 0.5), pupilY = 0.5 + 0.28 * (targetY - 0.5)
            let feat = GazeFeatures(
                pupilX: 0.5 + 0.30 * (target.x - 0.5),
                pupilY: 0.5 + 0.28 * (target.y - 0.5),
                yaw: 0.002, pitch: -0.001, roll: 0.0,
                faceX: 0.5, faceY: 0.5, iod: 0.12, faceWidth: 0.35,
                eyeOpenness: 0.9, confidence: 1.0, timestamp: date
            )
            pursuit.observe(features: feat, at: date)
        }

        let samples = pursuit.finish(gridSize: 5, minimumFramesPerBin: 3)
        // Must yield at least 20 spatial samples across the screen
        XCTAssertGreaterThanOrEqual(samples.count, 20)

        let map = try GazeCalibrator().calibrate(
            samples: samples,
            screenWidth: 1440,
            screenHeight: 900
        )

        XCTAssertTrue(map.isCalibrated)
        XCTAssertLessThan(map.validationErrorPixels, 50.0, "Smooth pursuit calibration must achieve < 50 px precision")
    }
}
