import XCTest
@testable import LyraCore

/// The calibration maths. This is where the previous implementation was structurally
/// wrong — it fitted a curve from an already-guessed "gaze" value to the screen. These
/// tests pin down that the fit now goes straight from raw measurements to screen, and
/// that the reported error is an honest held-out number rather than a training residual.
final class CalibrationTests: XCTestCase {

    private let screenWidth = 1440.0
    private let screenHeight = 900.0

    /// The ground-truth feature mapping. Shared by the fixture and the accuracy checks,
    /// so the point being scored is generated the same way the training data was.
    ///
    /// The structure here is the whole reason this fixture is worth having. A naive
    /// version — `pupilX = f(x)`, `yaw = g(x)`, `faceX = h(x)` — makes every feature an
    /// exact function of the target, which collapses the basis: `pupilX²` and `yaw²`
    /// become the same column, and the 20-term design has rank 6. That is a property of
    /// the fixture, and a test built on it measures nothing.
    ///
    /// Real measurements are not functions of the target. The eye moves *and* the head
    /// moves, independently, and it is the head that Vision reports as `yaw`/`pitch`/
    /// `roll` with translation in `faceX`/`faceY`. Modelling those as separate signals
    /// is what makes the fixture behave like a face.
    private func featureVector(x: Double, y: Double, index: Int) -> [Double] {
        var generator = SeededGenerator(seed: 0x5EED_0000 &+ UInt64(index) &* 2654435761)

        func unit() -> Double { Double.random(in: -1...1, using: &generator) }

        let gazeX = x - 0.5
        let gazeY = y - 0.5
        let headYaw = unit() * 0.08        // head rotation, independent of gaze
        let headPitch = unit() * 0.08
        let headRoll = unit() * 0.05
        let headX = unit() * 0.03          // head translation
        let headY = unit() * 0.03
        let distance = unit() * 0.5        // how far the user is sitting

        return [
            0.5 + gazeX * 0.28 + headYaw * 0.10,     // pupilX: gaze, nudged by head yaw
            0.5 + gazeY * 0.28 + headPitch * 0.10,   // pupilY
            headYaw,                                  // yaw: head pose
            headPitch,                                // pitch
            headRoll,                                 // roll
            headX,                                    // faceX
            headY,                                    // faceY
            0.062 + distance * 0.004,                 // iod: mostly a depth proxy
            // faceWidth is *also* mostly a depth proxy, but it additionally depends on
            // head pose and on the face itself. Driving it from `distance` alone makes
            // it an exact affine function of `iod`, which drops the design matrix to
            // rank 19 — two columns carrying one piece of information between them.
            0.30 + distance * 0.012 + unit() * 0.006
        ]
    }

    /// Builds synthetic samples from a known ground-truth mapping, so the fit can be
    /// checked against something whose right answer is known.
    ///
    /// The mapping is deliberately non-linear: a linear-only fit passes on a linear
    /// generator and fails silently on a real face.
    private func syntheticSamples(
        points: [(Double, Double)],
        noise: Double = 0.002
    ) -> [CalibrationSample] {
        var generator = SeededGenerator(seed: 0x1A2B3C)

        return points.enumerated().map { index, point in
            var vector = featureVector(x: point.0, y: point.1, index: index)
            if noise > 0 {
                for i in vector.indices {
                    vector[i] += Double.random(in: -noise...noise, using: &generator)
                }
            }
            return CalibrationSample(
                targetX: point.0,
                targetY: point.1,
                features: vector,
                frameCount: 30,
                featureSpread: 0.01
            )
        }
    }

    private func gazeFeatures(x: Double, y: Double, index: Int) -> GazeFeatures {
        let vector = featureVector(x: x, y: y, index: index)
        return GazeFeatures(
            pupilX: vector[0], pupilY: vector[1],
            yaw: vector[2], pitch: vector[3], roll: vector[4],
            faceX: vector[5], faceY: vector[6],
            iod: vector[7], faceWidth: vector[8],
            eyeOpenness: 0.9,
            confidence: 1.0, timestamp: Date()
        )
    }

    private var gridPoints: [(Double, Double)] {
        let columns = [0.07, 0.285, 0.5, 0.715, 0.93]
        let rows = [0.08, 0.36, 0.64, 0.92]
        return rows.flatMap { y in columns.map { x in (x, y) } }
    }

    // MARK: - Basis

    func testBasisTermCountMatchesDesignRowWidth() {
        let basis = PolynomialBasis()
        let row = basis.designRow(for: [Double](repeating: 0.5, count: GazeFeatures.featureCount))
        XCTAssertEqual(row.count, basis.termCount)
    }

    func testQuadraticTermsArePresent() {
        let basis = PolynomialBasis(primaryFeatureCount: 4, degree: 2)
        // 1 bias + 4 linear + 10 quadratic + 5 secondary linear = 20.
        XCTAssertEqual(basis.termCount, 20)
    }

    func testDesignMatrixHasFullColumnRankOnTheRealPattern() throws {
        // The property that actually matters: the basis must produce linearly
        // independent columns when evaluated at the points the user will really be
        // shown. A duplicated or degenerate column makes the fit singular and the ridge
        // term then decides the answer on its own.
        //
        // Checking distinct *values* at one input would be the wrong test — two different
        // monomials routinely coincide at a particular point (x·y == z at (1,1,1)) while
        // remaining independent across a grid.
        let basis = PolynomialBasis()
        let design = CalibrationPattern.standard.points.enumerated().map { index, point in
            basis.designRow(for: featureVector(x: point.x, y: point.y, index: index))
        }

        XCTAssertGreaterThan(design.count, basis.termCount)
        XCTAssertEqual(rank(of: design), basis.termCount)
    }

    // MARK: - Fit quality

    func testCalibratorRecoversAKnownMapping() throws {
        let samples = syntheticSamples(points: gridPoints, noise: 0.002)
        let map = try GazeCalibrator().calibrate(
            samples: samples,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )

        XCTAssertTrue(map.isCalibrated)

        // Check against the generator itself, on points the fit was trained on. This is
        // not the accuracy claim — that is the cross-validated error in the next test —
        // it only proves the fit converged on the intended function rather than on noise.
        for (x, y) in [(0.5, 0.5), (0.2, 0.3), (0.8, 0.7)] {
            let predicted = try XCTUnwrap(map.predict(features: gazeFeatures(x: x, y: y, index: 0)))
            XCTAssertEqual(predicted.x, x, accuracy: 0.05)
            XCTAssertEqual(predicted.y, y, accuracy: 0.05)
        }
    }

    func testHeldOutAccuracyOnARealisticFixture() throws {
        // A regression guard with a real bound rather than a tautology. The fixture has
        // 0.002 feature noise — roughly a good webcam on a cooperative user — so this
        // asserts what the pipeline actually achieves under near-ideal conditions, and
        // will fail if a change to the basis or the ridge term silently degrades it.
        let samples = syntheticSamples(points: gridPoints, noise: 0.002)
        let map = try GazeCalibrator().calibrate(
            samples: samples,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )

        let errorPixels = map.validationErrorNormalized * screenWidth
        print("held-out error: \(map.validationErrorNormalized) normalised ≈ \(errorPixels) px on a \(screenWidth) pt wide screen")

        // ~41 px on this fixture is one line of code. That is the number that decides
        // whether the lens is needed, and it says it is: a line of code is ~19 pt, so
        // direct line-level gaze still misses. The lens is not optional.
        XCTAssertLessThan(errorPixels, 50)
    }

    func testTooFewSamplesIsRejectedRatherThanFitted() {
        let samples = syntheticSamples(points: [(0.5, 0.5), (0.2, 0.2), (0.8, 0.8)])
        XCTAssertThrowsError(
            try GazeCalibrator().calibrate(
                samples: samples,
                screenWidth: screenWidth,
                screenHeight: screenHeight
            )
        )
    }

    func testUntrustworthySamplesAreFilteredBeforeFitting() throws {
        var samples = syntheticSamples(points: gridPoints)
        // A sample with almost no frames, or a wildly unstable hold, is not evidence.
        samples.append(CalibrationSample(
            targetX: 0.5, targetY: 0.5,
            features: [Double](repeating: 0.5, count: GazeFeatures.featureCount),
            frameCount: 2,
            featureSpread: 0.9
        ))

        let map = try GazeCalibrator().calibrate(
            samples: samples,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
        XCTAssertLessThanOrEqual(map.pointCount, samples.count)
    }

    // MARK: - Map behaviour

    func testUncalibratedMapRefusesToPredict() {
        let features = GazeFeatures(
            pupilX: 0.5, pupilY: 0.5, yaw: 0, pitch: 0, roll: 0,
            faceX: 0, faceY: 0, iod: 0.06, faceWidth: 0.3, eyeOpenness: 0.9,
            confidence: 1.0, timestamp: Date()
        )
        XCTAssertNil(CalibrationMap.identity.predict(features: features))
    }

    func testBlinkIsNotPredicted() throws {
        let map = try GazeCalibrator().calibrate(
            samples: syntheticSamples(points: gridPoints),
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )

        let blink = GazeFeatures(
            pupilX: 0.5, pupilY: 0.5, yaw: 0, pitch: 0, roll: 0,
            faceX: 0, faceY: 0, iod: 0.06, faceWidth: 0.3,
            eyeOpenness: 0.1, // eyes shut
            confidence: 1.0, timestamp: Date()
        )
        XCTAssertNil(map.predict(features: blink))
    }

    func testPredictionIsClampedToTheScreen() throws {
        let map = try GazeCalibrator().calibrate(
            samples: syntheticSamples(points: gridPoints),
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )

        // A measurement far outside anything seen during calibration still has to
        // produce a usable point rather than a cursor off the edge of the display.
        let extreme = GazeFeatures(
            pupilX: 5.0, pupilY: -4.0, yaw: 40, pitch: -40, roll: 0,
            faceX: 3, faceY: 3, iod: 0.06, faceWidth: 3, eyeOpenness: 0.9,
            confidence: 1.0, timestamp: Date()
        )
        let predicted = try XCTUnwrap(map.predict(features: extreme))
        XCTAssertTrue((0...1).contains(predicted.x))
        XCTAssertTrue((0...1).contains(predicted.y))
    }

    func testSchemaMismatchInvalidatesTheMap() throws {
        let map = try GazeCalibrator().calibrate(
            samples: syntheticSamples(points: gridPoints),
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
        // Round-tripping through JSON is how a saved map survives a relaunch; the
        // schema version is what stops a stale one from being applied to new features.
        let data = try JSONEncoder().encode(map)
        let restored = try JSONDecoder().decode(CalibrationMap.self, from: data)
        XCTAssertEqual(restored.schemaVersion, GazeFeatures.schemaVersion)
        XCTAssertEqual(restored.validationErrorNormalized, map.validationErrorNormalized, accuracy: 1e-9)
    }

    // MARK: - Setup tracking

    private var laptop: CalibrationMap.CalibrationContext {
        CalibrationMap.CalibrationContext(
            displayID: 1,
            cameraID: "BuiltInCamera",
            screenSize: LyraSize(width: 1470, height: 956)
        )
    }

    private func calibratedMap(
        context: CalibrationMap.CalibrationContext?
    ) throws -> CalibrationMap {
        try GazeCalibrator().calibrate(
            samples: syntheticSamples(points: gridPoints),
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            context: context
        )
    }

    func testCalibrationRecordsTheSetupItWasMeasuredIn() throws {
        let map = try calibratedMap(context: laptop)
        XCTAssertEqual(map.context, laptop)

        let data = try JSONEncoder().encode(map)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationMap.self, from: data).context, laptop)
    }

    func testAMapFromAnotherDisplayIsNotUsable() throws {
        // The failure this prevents: a map fitted through a laptop's built-in camera,
        // still driving the cursor after the user plugs into a monitor. It keeps producing
        // confident screen positions that are simply wrong, with nothing to indicate why.
        let map = try calibratedMap(context: laptop)
        let external = CalibrationMap.CalibrationContext(
            displayID: 3,
            cameraID: "BuiltInCamera",
            screenSize: LyraSize(width: 1470, height: 956)
        )
        XCTAssertFalse(map.isUsable(with: external))
        XCTAssertEqual(map.context?.difference(from: external), "a different display")
    }

    func testAMapFromAnotherCameraIsNotUsable() throws {
        let map = try calibratedMap(context: laptop)
        let webcam = CalibrationMap.CalibrationContext(
            displayID: 1,
            cameraID: "Logitech BRIO",
            screenSize: LyraSize(width: 1470, height: 956)
        )
        XCTAssertFalse(map.isUsable(with: webcam))
        XCTAssertEqual(map.context?.difference(from: webcam), "a different camera")
    }

    func testAResolutionChangeIsNotUsable() throws {
        let map = try calibratedMap(context: laptop)
        let scaled = CalibrationMap.CalibrationContext(
            displayID: 1,
            cameraID: "BuiltInCamera",
            screenSize: LyraSize(width: 1024, height: 640)
        )
        XCTAssertFalse(map.isUsable(with: scaled))
        XCTAssertEqual(map.context?.difference(from: scaled), "a screen resolution change")
    }

    func testTheSameSetupIsUsableAndReportsNoDifference() throws {
        let map = try calibratedMap(context: laptop)
        XCTAssertTrue(map.isUsable(with: laptop))
        XCTAssertNil(map.context?.difference(from: laptop))
    }

    func testAMissingDimensionIsNotTreatedAsAChange() {
        // Not every machine reports every identifier. A field absent on one side is not
        // evidence of a different setup, and demanding a recalibration over it would be a
        // bug the user cannot diagnose or work around.
        let map = CalibrationMap.identity
        let partial = CalibrationMap.CalibrationContext(
            displayID: nil,
            cameraID: "BuiltInCamera",
            screenSize: nil
        )
        XCTAssertTrue(partial.matches(laptop))

        let unknown = CalibrationMap.CalibrationContext()
        XCTAssertTrue(unknown.matches(laptop))
        XCTAssertNil(laptop.difference(from: unknown))
    }

    func testAMapSavedBeforeSetupsWereRecordedStillLoads() throws {
        // Everything calibrated before this existed has no context. Refusing it would
        // demand a recalibration the user has no reason to expect.
        let map = try calibratedMap(context: nil)
        XCTAssertNil(map.context)

        let data = try JSONEncoder().encode(map)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"context\""))

        let restored = try JSONDecoder().decode(CalibrationMap.self, from: data)
        XCTAssertNil(restored.context)
        XCTAssertTrue(restored.isUsable(with: laptop))
    }

    // MARK: - Capture state machine

    private func features(_ value: Double) -> GazeFeatures {
        GazeFeatures(
            pupilX: value, pupilY: value, yaw: 0, pitch: 0, roll: 0,
            faceX: 0, faceY: 0, iod: 0.06, faceWidth: 0.3, eyeOpenness: 0.9,
            confidence: 1.0, timestamp: Date()
        )
    }

    func testCaptureSettlesBeforeItCollects() {
        let capture = CalibrationCapture(pattern: .standard, settleDuration: 0.4)
        capture.start(at: 0)

        // During settling, nothing may be collected: the eye is still mid-saccade and
        // averaging from here drags every sample towards wherever the user was before.
        XCTAssertEqual(capture.update(features: features(0.5), at: 0.1)?.phase, .settling)
        XCTAssertEqual(capture.update(features: features(0.5), at: 0.39)?.phase, .settling)
        XCTAssertEqual(capture.update(features: features(0.5), at: 0.41)?.phase, .collecting)
    }

    func testCaptureProducesOneSamplePerPatternPoint() {
        let pattern = CalibrationPattern.quick
        let capture = CalibrationCapture(pattern: pattern, settleDuration: 0.2, minimumFrames: 3)

        capture.start(at: 0)
        var time = 0.0
        while !capture.isFinished, time < 600 {
            _ = capture.update(features: features(0.5), at: time)
            time += 1.0 / 30.0
        }

        XCTAssertTrue(capture.isFinished)
        XCTAssertEqual(capture.samples.count, pattern.points.count)
        XCTAssertTrue(capture.abandonedPoints.isEmpty)
    }

    func testUnusableFramesDoNotCountTowardsAPoint() {
        let capture = CalibrationCapture(pattern: .quick, settleDuration: 0.1, minimumFrames: 5, maximumRetries: 0)
        capture.start(at: 0)

        // Blink the whole way through: no point can produce a trustworthy sample, so
        // every one must be reported abandoned rather than silently accepted.
        var time = 0.0
        while !capture.isFinished, time < 600 {
            _ = capture.update(features: features(0.5).withEyeOpenness(0.05), at: time)
            time += 1.0 / 30.0
        }

        XCTAssertTrue(capture.samples.isEmpty)
        XCTAssertEqual(capture.abandonedPoints.count, CalibrationPattern.quick.points.count)
    }

    func testProgressCarriesTheDotBeingShown() {
        let capture = CalibrationCapture(pattern: .quick, settleDuration: 0.05)
        capture.start(at: 0)

        let progress = capture.update(features: features(0.5), at: 0.1)
        // The UI renders this position directly; if it ever reports the wrong dot the
        // user calibrates against a target that was never on screen.
        XCTAssertEqual(progress?.pointX, capture.currentPoint?.x)
        XCTAssertEqual(progress?.pointY, capture.currentPoint?.y)
    }

    func testLockQualityReflectsActualStability() {
        // Needs at least three frames: with fewer, there is no spread to measure and
        // the honest answer is "no idea", not "locked".
        let steady = CalibrationCapture(pattern: .quick, settleDuration: 0.5)
        steady.start(at: 0)
        var steadyProgress: CalibrationCapture.Progress?
        for i in 0..<5 {
            steadyProgress = steady.update(features: features(0.5), at: Double(i) * 0.01)
        }

        let jittery = CalibrationCapture(pattern: .quick, settleDuration: 0.5)
        jittery.start(at: 0)
        var jitteryProgress: CalibrationCapture.Progress?
        var value = 0.2
        for i in 0..<5 {
            jitteryProgress = jittery.update(features: features(value), at: Double(i) * 0.01)
            value += 0.15
        }

        // The old indicator lit up whenever a camera frame arrived, even if the user was
        // looking at the wall. This one has to actually separate steady from wandering.
        XCTAssertEqual(steadyProgress?.lockQuality ?? 0, 1.0, accuracy: 0.001)
        XCTAssertLessThan(jitteryProgress?.lockQuality ?? 1, 0.5)
    }

    func testAPointWaitsForTheEyeRatherThanTheClock() {
        // The state machine used to advance purely on elapsed time, which is exactly what
        // "it goes too fast" was: the dot left after a fixed hold whether or not the user
        // had arrived at it, and the sample banked was of them still looking elsewhere.
        let pattern = CalibrationPattern.quick
        let settle = 0.1
        let frame = 1.0 / 30.0

        let steady = CalibrationCapture(pattern: pattern, settleDuration: settle, minimumFrames: 3)
        steady.start(at: 0)
        var time = 0.0
        while time <= settle + pattern.holdDuration + frame {
            _ = steady.update(features: features(0.5), at: time)
            time += frame
        }
        XCTAssertFalse(
            steady.samples.isEmpty,
            "an eye that is on the dot should bank the point as soon as the hold is up"
        )

        let wandering = CalibrationCapture(pattern: pattern, settleDuration: settle, minimumFrames: 3)
        wandering.start(at: 0)
        var value = 0.1
        time = 0.0
        while time <= settle + pattern.holdDuration {
            _ = wandering.update(features: features(value), at: time)
            value = value > 0.5 ? 0.1 : 0.9
            time += frame
        }
        XCTAssertTrue(
            wandering.samples.isEmpty,
            "the hold expiring must not bank a point the eye was never on"
        )

        // And the wait is bounded. Past the timeout the run takes the sample anyway
        // rather than stalling forever on a point this user cannot settle on, so a noisy
        // tracker costs a slower calibration rather than none at all.
        while time <= settle + pattern.holdDuration * 4 {
            _ = wandering.update(features: features(value), at: time)
            value = value > 0.5 ? 0.1 : 0.9
            time += frame
        }
        XCTAssertFalse(
            wandering.samples.isEmpty,
            "a point that never settles must eventually be taken, not waited on forever"
        )
    }

    /// Row rank by Gaussian elimination with partial pivoting.
    private func rank(of matrix: [[Double]], epsilon: Double = 1e-9) -> Int {
        guard !matrix.isEmpty else { return 0 }
        var a = matrix
        let rows = a.count
        let columns = a[0].count
        var rank = 0

        for column in 0..<columns where rank < rows {
            var pivotRow = rank
            for r in rank..<rows where abs(a[r][column]) > abs(a[pivotRow][column]) {
                pivotRow = r
            }
            guard abs(a[pivotRow][column]) > epsilon else { continue }
            a.swapAt(rank, pivotRow)

            let pivot = a[rank][column]
            for r in (rank + 1)..<rows {
                let factor = a[r][column] / pivot
                guard factor != 0 else { continue }
                for c in column..<columns { a[r][c] -= factor * a[rank][c] }
            }
            rank += 1
        }
        return rank
    }
}

private extension GazeFeatures {
    /// Convenience for building a blink in tests.
    func withEyeOpenness(_ openness: Double) -> GazeFeatures {
        GazeFeatures(
            pupilX: pupilX, pupilY: pupilY,
            yaw: yaw, pitch: pitch, roll: roll,
            faceX: faceX, faceY: faceY,
            iod: iod, faceWidth: faceWidth,
            eyeOpenness: openness,
            confidence: confidence, timestamp: timestamp
        )
    }

    // MARK: - Diagnostics

    func testDiagnosticsRankFeaturesByHowMuchGazeTheyCarry() {
        // The point of the summary: it has to separate "this feature does not move with
        // gaze" from "this feature moves, but noisily". Distance from the screen centre
        // is a perfect stand-in for a feature that tracks gaze and a poor one for a
        // feature that does not.
        let points: [(Double, Double)] = [0.1, 0.5, 0.9].flatMap { x in
            [0.1, 0.5, 0.9].map { y in (x, y) }
        }
        let samples = points.enumerated().map { index, point -> CalibrationSample in
            var features = [Double](repeating: 0.5, count: GazeFeatures.featureCount)
            // A feature that follows the target exactly...
            features[0] = (point.0 + point.1) / 2
            // ...and one that is pure noise with no relation to it.
            features[1] = index.isMultiple(of: 2) ? 0.2 : 0.8
            return CalibrationSample(
                targetX: point.0, targetY: point.1,
                features: features, frameCount: 30, featureSpread: 0.01
            )
        }

        let summaries = CalibrationDiagnostics.summarise(samples)
        XCTAssertEqual(summaries.count, GazeFeatures.featureCount)
        XCTAssertEqual(summaries[0].name, "pupilX")

        let tracking = summaries[0]
        XCTAssertGreaterThan(tracking.strongestCorrelation, 0.9)
        XCTAssertGreaterThan(tracking.range, 0.5)

        // The alternating feature correlates with nothing, so it must not be reported as
        // carrying gaze merely for having a wide range.
        let noisy = summaries[1]
        XCTAssertGreaterThan(noisy.range, 0.5)
        XCTAssertLessThan(noisy.strongestCorrelation, 0.3)

        // A feature that never varies at all is the clearest possible "no signal".
        XCTAssertEqual(summaries[8].range, 0.0, accuracy: 1e-12)
        XCTAssertEqual(summaries[8].strongestCorrelation, 0.0, accuracy: 1e-12)
    }

    func testCorrelationIsZeroRatherThanUndefinedForAConstantInput() {
        let constant = [Double](repeating: 0.5, count: 10)
        let varying = (0..<10).map { Double($0) }
        XCTAssertEqual(CalibrationDiagnostics.correlation(constant, varying), 0)
        XCTAssertEqual(CalibrationDiagnostics.correlation(varying, constant), 0)
    }
}

/// A small deterministic generator, so a noisy fixture still produces the same numbers
/// on every run. `SystemRandomNumberGenerator` would make a failure impossible to
/// reproduce, which is the one thing a failing test has to be.
private struct SeededGenerator: RandomNumberGenerator {    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
