import Foundation

/// WebGazer 9-point multi-click calibration engine.
///
/// Implements the research paradigm from WebGazer (Papoutsaki et al., IJCAI 2016):
/// 1. 9 points in a 3×3 grid (at 0.10, 0.50, 0.90 for X and Y) are active on screen simultaneously.
/// 2. The user clicks each of the 9 points 5 times (45 total samples) in any order while looking at them.
/// 3. Each click pairs the ground-truth target coordinate with buffered ocular/facial landmarks.
/// 4. After all 9 points reach 5 clicks, Ridge Regression (L2 regularization) fits the polynomial mapping.
/// 5. A 3.5-second precision verification phase at screen center (0.50, 0.50) measures live accuracy percentage.
public final class WebGazerCalibration: @unchecked Sendable {

    public struct PointState: Sendable, Identifiable, Equatable {
        public let id: Int
        /// Normalised coordinate (0.10, 0.50, or 0.90)
        public let x: Double
        public let y: Double
        public var clicks: Int
        public let clicksRequired: Int

        public var isComplete: Bool { clicks >= clicksRequired }
        public var remainingClicks: Int { max(0, clicksRequired - clicks) }
        public var progressFraction: Double {
            Double(clicks) / Double(max(clicksRequired, 1))
        }

        public init(id: Int, x: Double, y: Double, clicks: Int = 0, clicksRequired: Int = 5) {
            self.id = id
            self.x = x
            self.y = y
            self.clicks = clicks
            self.clicksRequired = clicksRequired
        }
    }

    public enum Phase: Sendable, Equatable {
        case notStarted
        case calibrating
        case fitting
        case precisionVerification(timeRemaining: Double, duration: Double, accuracyPercentage: Double)
        case completed(accuracyPercentage: Double, errorPixels: Double)
    }

    public struct Progress: Sendable, Equatable {
        public let points: [PointState]
        public let totalClicks: Int
        public let requiredClicks: Int
        public let completedPointsCount: Int
        public let isAllPointsComplete: Bool
        public let phase: Phase

        public var overallProgressFraction: Double {
            Double(totalClicks) / Double(max(requiredClicks, 1))
        }
    }

    // MARK: - Properties

    public let clicksPerPoint: Int
    public let verificationDuration: Double
    private let frameBufferLimit: Int
    private let minimumFrames: Int
    private let clickTolerancePoints: Double

    public private(set) var points: [PointState]
    public private(set) var samples: [CalibrationSample] = []
    public private(set) var rejectedClicks = 0
    public private(set) var droppedClicks = 0
    public private(set) var phase: Phase = .notStarted
    public private(set) var fittedMap: CalibrationMap?

    private var frames: [GazeFeatures] = []
    private var verificationErrors: [Double] = []
    private var verificationTimeRemaining: Double = 3.5
    private let lock = NSLock()

    // MARK: - Init

    public init(
        clicksPerPoint: Int = 5,
        verificationDuration: Double = 3.5,
        frameBufferLimit: Int = 20,
        minimumFrames: Int = 3,
        clickTolerancePoints: Double = 120
    ) {
        self.clicksPerPoint = max(clicksPerPoint, 1)
        self.verificationDuration = verificationDuration
        self.frameBufferLimit = max(frameBufferLimit, minimumFrames)
        self.minimumFrames = max(minimumFrames, 2)
        self.clickTolerancePoints = clickTolerancePoints

        // 3×3 grid: uses CalibrationPattern.webGazer9 for safe screen positioning
        self.points = CalibrationPattern.webGazer9.points.map {
            PointState(
                id: $0.id,
                x: $0.x,
                y: $0.y,
                clicks: 0,
                clicksRequired: clicksPerPoint
            )
        }
    }

    // MARK: - State

    public var totalPointsCount: Int { points.count }
    public var requiredClicks: Int { totalPointsCount * clicksPerPoint }
    public var totalClicks: Int { points.reduce(0) { $0 + $1.clicks } }
    public var completedPointsCount: Int { points.filter(\.isComplete).count }
    public var isAllPointsComplete: Bool { points.allSatisfy(\.isComplete) }

    public var progress: Progress {
        lock.lock()
        defer { lock.unlock() }
        return Progress(
            points: points,
            totalClicks: totalClicks,
            requiredClicks: requiredClicks,
            completedPointsCount: completedPointsCount,
            isAllPointsComplete: isAllPointsComplete,
            phase: phase
        )
    }

    // MARK: - Actions

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
        samples.removeAll()
        verificationErrors.removeAll()
        rejectedClicks = 0
        droppedClicks = 0
        fittedMap = nil
        verificationTimeRemaining = verificationDuration

        for i in 0..<points.count {
            points[i] = PointState(
                id: points[i].id,
                x: points[i].x,
                y: points[i].y,
                clicks: 0,
                clicksRequired: clicksPerPoint
            )
        }
        phase = .calibrating
    }

    /// Buffers incoming eye features for pairing with clicks or verification.
    public func observe(features: GazeFeatures) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(features)
        if frames.count > frameBufferLimit {
            frames.removeFirst()
        }
    }

    /// Registers a click directly on a target point by ID.
    @discardableResult
    public func registerClick(pointIndex: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registerClickLocked(pointIndex: pointIndex)
    }

    private func registerClickLocked(pointIndex: Int) -> Bool {
        guard phase == .calibrating, pointIndex >= 0, pointIndex < points.count else {
            return false
        }
        guard !points[pointIndex].isComplete else {
            return false
        }

        let target = points[pointIndex]
        guard let sample = CalibrationSample.aggregate(
            frames: frames,
            targetX: target.x,
            targetY: target.y,
            minimumFrames: minimumFrames
        ) else {
            droppedClicks += 1
            return false
        }

        samples.append(sample)
        points[pointIndex].clicks += 1

        if isAllPointsComplete {
            phase = .fitting
        }

        return true
    }

    /// Registers a click at a given screen coordinate.
    ///
    /// Finds the closest calibration point that still needs clicks and falls within hit tolerance.
    @discardableResult
    public func registerClick(
        atNormalized point: (x: Double, y: Double),
        screenSize: LyraSize
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .calibrating else { return false }

        // Find nearest point within tolerance that is not yet completed
        var bestIndex: Int?
        var minDistance = Double.infinity

        for (idx, target) in points.enumerated() {
            let dx = (point.x - target.x) * screenSize.width
            let dy = (point.y - target.y) * screenSize.height
            let dist = (dx * dx + dy * dy).squareRoot()

            if dist < minDistance {
                minDistance = dist
                bestIndex = idx
            }
        }

        guard let targetIdx = bestIndex, minDistance <= clickTolerancePoints else {
            rejectedClicks += 1
            return false
        }

        if points[targetIdx].isComplete {
            // Already completed, but was clicked within bounds
            return false
        }

        return registerClickLocked(pointIndex: targetIdx)
    }

    /// Fits GazeCalibrator with Ridge Regression (L2 regularization).
    public func fit(
        screenWidth: Double,
        screenHeight: Double,
        context: CalibrationMap.CalibrationContext? = nil
    ) throws -> CalibrationMap {
        lock.lock()
        phase = .fitting
        let currentSamples = self.samples
        lock.unlock()

        let calibrator = GazeCalibrator(lambda: 1.0, minimumSamples: 9)
        let map = try calibrator.calibrate(
            samples: currentSamples,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            context: context
        )

        lock.lock()
        self.fittedMap = map
        startVerificationLocked()
        lock.unlock()

        return map
    }

    // MARK: - Precision Verification

    public func startVerification() {
        lock.lock()
        defer { lock.unlock() }
        startVerificationLocked()
    }

    private func startVerificationLocked() {
        verificationErrors.removeAll()
        verificationTimeRemaining = verificationDuration
        phase = .precisionVerification(
            timeRemaining: verificationTimeRemaining,
            duration: verificationDuration,
            accuracyPercentage: 100.0
        )
    }

    /// Updates precision verification with a new frame during the 3.5s center test.
    public func observeVerification(
        features: GazeFeatures,
        screenSize: LyraSize,
        dt: Double
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard case .precisionVerification = phase, let map = fittedMap else { return }

        verificationTimeRemaining = max(0.0, verificationTimeRemaining - dt)

        if features.isUsable, let prediction = map.predict(features: features) {
            let dx = (prediction.x - 0.50) * screenSize.width
            let dy = (prediction.y - 0.50) * screenSize.height
            let errorDistance = (dx * dx + dy * dy).squareRoot()
            verificationErrors.append(errorDistance)
        }

        let accuracy = computeLiveAccuracyLocked()

        if verificationTimeRemaining <= 0 {
            let avgError = verificationErrors.isEmpty ? map.validationErrorPixels : (verificationErrors.reduce(0, +) / Double(verificationErrors.count))
            phase = .completed(accuracyPercentage: accuracy, errorPixels: avgError)
        } else {
            phase = .precisionVerification(
                timeRemaining: verificationTimeRemaining,
                duration: verificationDuration,
                accuracyPercentage: accuracy
            )
        }
    }

    /// Computes accuracy percentage based on screen-center fixation error.
    public func computeLiveAccuracy() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return computeLiveAccuracyLocked()
    }

    private func computeLiveAccuracyLocked() -> Double {
        if verificationErrors.isEmpty {
            if let map = fittedMap, map.validationErrorPixels.isFinite {
                let accuracy = max(0.0, min(100.0, (1.0 - min(map.validationErrorPixels, 300.0) / 300.0) * 100.0))
                return (accuracy * 10.0).rounded() / 10.0
            }
            return 0.0
        }
        let meanError = verificationErrors.reduce(0, +) / Double(verificationErrors.count)
        // 0 error -> 100%, 70px -> ~88%, 150px -> ~65%, >=300px -> 0%
        let accuracy = max(0.0, min(100.0, (1.0 - min(meanError, 300.0) / 300.0) * 100.0))
        return (accuracy * 10.0).rounded() / 10.0
    }
}
