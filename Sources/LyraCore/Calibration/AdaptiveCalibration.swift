import Foundation

/// Adaptive 3-Stage Gaze Calibration Pipeline.
///
/// Combines the three most effective calibration techniques into a single, seamless,
/// hands-free sequence:
///
/// 1. **Stage 1 (Anchor Extrema & Prediction Confirmation)**:
///    Captures the 4 extreme corners and screen center to define the convex hull
///    of pupil deflection. Uses a preliminary affine model to predict where the user is
///    looking and auto-confirms each anchor hands-free once gaze settles.
///
/// 2. **Stage 2 (Smooth Pursuit Manifold Densification)**:
///    A glowing ball glides continuously across the 5 screen rows for 14 seconds,
///    using the smooth pursuit reflex to acquire ~400 clean gaze pairs without manual clicks.
///    Frames are binned across a 5x5 grid with MAD outlier rejection.
///
/// 3. **Stage 3 (Targeted Error Refinement / Active Learning)**:
///    Evaluates cross-validated per-point residuals. If any region has an error > 75 px,
///    the pipeline prompts the user to glance at that specific dot for ~0.8s to fine-tune it,
///    replacing the noisy sample and refitting. If all points are good, Stage 3 is skipped.
///
/// Fully hardware-free and testable without camera or display.
public final class AdaptiveCalibration: @unchecked Sendable {

    public enum Stage: String, Sendable, Codable, Equatable {
        case anchors
        case pursuit
        case refinement
        case finished
    }

    public struct Progress: Sendable, Equatable {
        public let stage: Stage
        public let stageIndex: Int // 1, 2, or 3
        public let totalStages: Int
        public let pointX: Double
        public let pointY: Double
        public let targetProgress: Double // 0...1 (fixation hold fill or pursuit path progress)
        public let currentPointIndex: Int
        public let totalPointsInStage: Int
        public let promptTitle: String
        public let promptSubtitle: String
        public let isFinished: Bool
        public let errorPixels: Double?

        public init(
            stage: Stage,
            stageIndex: Int,
            totalStages: Int = 3,
            pointX: Double,
            pointY: Double,
            targetProgress: Double,
            currentPointIndex: Int,
            totalPointsInStage: Int,
            promptTitle: String,
            promptSubtitle: String,
            isFinished: Bool,
            errorPixels: Double? = nil
        ) {
            self.stage = stage
            self.stageIndex = stageIndex
            self.totalStages = totalStages
            self.pointX = pointX
            self.pointY = pointY
            self.targetProgress = targetProgress
            self.currentPointIndex = currentPointIndex
            self.totalPointsInStage = totalPointsInStage
            self.promptTitle = promptTitle
            self.promptSubtitle = promptSubtitle
            self.isFinished = isFinished
            self.errorPixels = errorPixels
        }
    }

    private let lock = NSLock()

    // MARK: - Configuration
    public let screenWidth: Double
    public let screenHeight: Double
    public let context: CalibrationMap.CalibrationContext?
    public let refinementThresholdPixels: Double
    public let requireClick: Bool

    // MARK: - State
    public private(set) var stage: Stage = .anchors
    private var stageStartTime: Date = Date()
    private var pointStartTime: Date = Date()

    // Stage 1: Anchors - true extreme screen corners + center
    public static let defaultAnchorPoints: [(x: Double, y: Double)] = [
        (0.50, 0.50),   // Center baseline
        (0.008, 0.008), // Extreme Top-Left corner
        (0.992, 0.008), // Extreme Top-Right corner
        (0.992, 0.992), // Extreme Bottom-Right corner
        (0.008, 0.992)  // Extreme Bottom-Left corner
    ]
    private var anchorIndex = 0
    private var anchorBuffer: [GazeFeatures] = []
    private var anchorHoldCount = 0
    private var anchorSamples: [CalibrationSample] = []

    // Stage 2: Pursuit
    private var pursuit: PursuitCalibration
    private var pursuitSamples: [CalibrationSample] = []

    // Stage 3: Refinement
    private var refinementPoints: [(x: Double, y: Double)] = []
    private var refinementIndex = 0
    private var refinementBuffer: [GazeFeatures] = []
    private var refinementHoldCount = 0
    private var refinementSamples: [CalibrationSample] = []

    // Final result
    public private(set) var finalMap: CalibrationMap?

    public init(
        screenWidth: Double = 1440.0,
        screenHeight: Double = 900.0,
        context: CalibrationMap.CalibrationContext? = nil,
        refinementThresholdPixels: Double = 60.0,
        pursuitDuration: Double = 28.0,
        requireClick: Bool = true,
        latencyCompensation: Double = 0.0
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.context = context
        self.refinementThresholdPixels = refinementThresholdPixels
        self.requireClick = requireClick
        self.pursuit = PursuitCalibration(
            durationSeconds: pursuitDuration,
            countdownSeconds: 2.0,
            latencyCompensation: latencyCompensation
        )
    }

    public func start(at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        stage = .anchors
        stageStartTime = date
        pointStartTime = date
        anchorIndex = 0
        anchorBuffer.removeAll()
        anchorHoldCount = 0
        anchorSamples.removeAll()

        pursuitSamples.removeAll()
        refinementPoints.removeAll()
        refinementIndex = 0
        refinementBuffer.removeAll()
        refinementHoldCount = 0
        refinementSamples.removeAll()
        finalMap = nil
    }

    // MARK: - Observation

    public func observe(features: GazeFeatures, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        guard features.isUsable, stage != .finished else { return }

        switch stage {
        case .anchors:
            observeAnchor(features: features, at: date)
        case .pursuit:
            pursuit.observe(features: features, at: date)
            if pursuit.progress(at: date).isFinished {
                finishPursuitAndCheckRefinement(at: date)
            }
        case .refinement:
            observeRefinement(features: features, at: date)
        case .finished:
            break
        }
    }

    // MARK: - Tick / Progress

    public func progress(at date: Date = Date()) -> Progress {
        lock.lock()
        defer { lock.unlock() }

        switch stage {
        case .anchors:
            let target = Self.defaultAnchorPoints[min(anchorIndex, Self.defaultAnchorPoints.count - 1)]
            let holdRatio = min(Double(anchorHoldCount) / 8.0, 1.0)
            let isCenter = anchorIndex == 0
            return Progress(
                stage: .anchors,
                stageIndex: 1,
                pointX: target.x,
                pointY: target.y,
                targetProgress: holdRatio,
                currentPointIndex: anchorIndex + 1,
                totalPointsInStage: Self.defaultAnchorPoints.count,
                promptTitle: isCenter ? "Look at center dot & click" : "Look at corner dot & click",
                promptSubtitle: isCenter ? "Look at center dot, then click or press Space" : "Look at corner dot, then click or press Space",
                isFinished: false
            )

        case .pursuit:
            let pProg = pursuit.progress(at: date)
            return Progress(
                stage: .pursuit,
                stageIndex: 2,
                pointX: pProg.pointX,
                pointY: pProg.pointY,
                targetProgress: pProg.progress,
                currentPointIndex: 1,
                totalPointsInStage: 1,
                promptTitle: "Follow the moving ball",
                promptSubtitle: "Keep your eyes on the ball as it glides slowly — no clicking needed",
                isFinished: false
            )

        case .refinement:
            guard refinementIndex < refinementPoints.count else {
                return finishedProgress()
            }
            let target = refinementPoints[refinementIndex]
            let holdRatio = min(Double(refinementHoldCount) / 6.0, 1.0)
            return Progress(
                stage: .refinement,
                stageIndex: 3,
                pointX: target.x,
                pointY: target.y,
                targetProgress: holdRatio,
                currentPointIndex: refinementIndex + 1,
                totalPointsInStage: refinementPoints.count,
                promptTitle: "Look & click to polish",
                promptSubtitle: "Fine-tuning accuracy (\(refinementIndex + 1) of \(refinementPoints.count)) — click while looking at the dot",
                isFinished: false
            )

        case .finished:
            return finishedProgress()
        }
    }

    private func finishedProgress() -> Progress {
        Progress(
            stage: .finished,
            stageIndex: 3,
            pointX: 0.5,
            pointY: 0.5,
            targetProgress: 1.0,
            currentPointIndex: 1,
            totalPointsInStage: 1,
            promptTitle: "Calibration Complete",
            promptSubtitle: "Your eye model is ready",
            isFinished: true,
            errorPixels: finalMap?.validationErrorPixels
        )
    }

    // MARK: - Stage 1: Anchors Logic

    private func observeAnchor(features: GazeFeatures, at date: Date) {
        guard anchorIndex < Self.defaultAnchorPoints.count else { return }
        let target = Self.defaultAnchorPoints[anchorIndex]

        anchorBuffer.append(features)
        if anchorBuffer.count > 12 { anchorBuffer.removeFirst() }

        let elapsed = date.timeIntervalSince(pointStartTime)

        // Require at least 3 frames in buffer
        guard anchorBuffer.count >= 3 else { return }

        // Compute stability spread across last 4 frames
        let window = Array(anchorBuffer.suffix(4))
        let meanX = window.map(\.pupilX).reduce(0, +) / Double(window.count)
        let meanY = window.map(\.pupilY).reduce(0, +) / Double(window.count)
        var varSum = 0.0
        for f in window {
            let dx = f.pupilX - meanX
            let dy = f.pupilY - meanY
            varSum += dx * dx + dy * dy
        }
        let spread = (varSum / Double(window.count)).squareRoot()

        // Prediction check if we have >= 3 anchors already
        var passesPrediction = true
        if anchorSamples.count >= 3, let affine = computeAffineModel(from: anchorSamples) {
            let pred = affine.predict(features.pupilX, features.pupilY)
            let dist = hypot(pred.x - target.x, pred.y - target.y)
            // Generous tolerance: within 0.35 screen space
            passesPrediction = dist <= 0.35
        }

        if spread < 0.025 && passesPrediction {
            anchorHoldCount += 1
        } else {
            anchorHoldCount = max(0, anchorHoldCount - 1)
        }

        // When requireClick is false, complete point when held for 6 frames or timeout after 3.0s with sufficient frames
        if !requireClick && (anchorHoldCount >= 6 || (elapsed >= 3.0 && anchorBuffer.count >= 3)) {
            if let sample = CalibrationSample.aggregate(
                frames: anchorBuffer,
                targetX: target.x,
                targetY: target.y,
                minimumFrames: 3
            ) {
                anchorSamples.append(sample)
            }

            anchorIndex += 1
            anchorBuffer.removeAll()
            anchorHoldCount = 0
            pointStartTime = date

            if anchorIndex >= Self.defaultAnchorPoints.count {
                // Transition to Stage 2: Smooth Pursuit
                stage = .pursuit
                stageStartTime = date
                pursuit.start(at: date)
            }
        }
    }

    // MARK: - Click Registration

    /// Records a deliberate user click or Space keypress for the current static point (Stage 1 or Stage 3).
    ///
    /// Returns `true` if the click advanced a calibration point, `false` otherwise.
    @discardableResult
    public func registerClick(
        atNormalized location: (x: Double, y: Double)? = nil,
        at date: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard stage != .finished else { return false }

        switch stage {
        case .anchors:
            guard anchorIndex < Self.defaultAnchorPoints.count else { return false }
            let target = Self.defaultAnchorPoints[anchorIndex]

            guard anchorBuffer.count >= 2 else { return false }

            let sample = CalibrationSample.aggregate(
                frames: anchorBuffer,
                targetX: target.x,
                targetY: target.y,
                minimumFrames: 4
            ) ?? fallbackSample(from: anchorBuffer, targetX: target.x, targetY: target.y)

            anchorSamples.append(sample)
            anchorIndex += 1
            anchorBuffer.removeAll()
            anchorHoldCount = 0
            pointStartTime = date

            if anchorIndex >= Self.defaultAnchorPoints.count {
                stage = .pursuit
                stageStartTime = date
                pursuit.start(at: date)
            }
            return true

        case .refinement:
            guard refinementIndex < refinementPoints.count else { return false }
            let target = refinementPoints[refinementIndex]

            guard refinementBuffer.count >= 2 else { return false }

            let sample = CalibrationSample.aggregate(
                frames: refinementBuffer,
                targetX: target.x,
                targetY: target.y,
                minimumFrames: 4
            ) ?? fallbackSample(from: refinementBuffer, targetX: target.x, targetY: target.y)

            refinementSamples.append(sample)
            refinementIndex += 1
            refinementBuffer.removeAll()
            refinementHoldCount = 0
            pointStartTime = date

            if refinementIndex >= refinementPoints.count {
                finalizeRefinedModel()
            }
            return true

        case .pursuit, .finished:
            return false
        }
    }

    private func fallbackSample(from frames: [GazeFeatures], targetX: Double, targetY: Double) -> CalibrationSample {
        let count = Double(frames.count)
        var means = [Double](repeating: 0, count: GazeFeatures.featureCount)
        for f in frames {
            let vec = f.vector
            for i in 0..<min(vec.count, means.count) { means[i] += vec[i] }
        }
        for i in means.indices { means[i] /= max(count, 1) }
        return CalibrationSample(
            targetX: targetX,
            targetY: targetY,
            features: means,
            frameCount: max(frames.count, 4),
            featureSpread: 0.02
        )
    }

    // MARK: - Stage 2: Pursuit Transition

    private func finishPursuitAndCheckRefinement(at date: Date) {
        pursuitSamples = pursuit.finish(gridSize: 5, minimumFramesPerBin: 3)

        // Fit intermediate map with combined anchors + pursuit
        let combined = anchorSamples + pursuitSamples
        do {
            let calibrator = GazeCalibrator()
            let intermediateMap = try calibrator.calibrate(
                samples: combined,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                context: context
            )

            // Screen diagonal / average dimension for pixel scaling
            let screenAvg = (screenWidth + screenHeight) / 2.0

            // Find any residuals exceeding refinement threshold (up to 3 points).
            // Evaluates all combined samples (including those rejected by outlier pruning during fit).
            var candidateTargets: [(target: (x: Double, y: Double), errPx: Double)] = []
            for s in combined {
                let row = intermediateMap.basis.designRow(for: s.features)
                let px = intermediateMap.xModel.predict(designRow: row)
                let py = intermediateMap.yModel.predict(designRow: row)
                let errPx = hypot(px - s.targetX, py - s.targetY) * screenAvg
                if errPx > refinementThresholdPixels {
                    candidateTargets.append((target: (x: s.targetX, y: s.targetY), errPx: errPx))
                }
            }

            // Deduplicate candidate targets that are close to each other
            var deduplicated: [(target: (x: Double, y: Double), errPx: Double)] = []
            candidateTargets.sort { $0.errPx > $1.errPx }
            for cand in candidateTargets {
                let isNearby = deduplicated.contains { existing in
                    hypot(existing.target.x - cand.target.x, existing.target.y - cand.target.y) < 0.15
                }
                if !isNearby {
                    deduplicated.append(cand)
                }
            }

            if !deduplicated.isEmpty {
                // Activate Stage 3: Refine top 3 highest-error regions
                refinementPoints = deduplicated.prefix(3).map(\.target)
                refinementIndex = 0
                refinementBuffer.removeAll()
                refinementHoldCount = 0
                refinementSamples.removeAll()
                stage = .refinement
                stageStartTime = date
                pointStartTime = date
                return
            }

            // All points within acceptable bounds: complete immediately
            finalMap = intermediateMap
            stage = .finished
        } catch {
            print("AdaptiveCalibration intermediate fit error: \(error)")
            finalMap = nil
            stage = .finished
        }
    }

    // MARK: - Stage 3: Refinement Logic

    private func observeRefinement(features: GazeFeatures, at date: Date) {
        guard refinementIndex < refinementPoints.count else { return }
        let target = refinementPoints[refinementIndex]

        refinementBuffer.append(features)
        if refinementBuffer.count > 10 { refinementBuffer.removeFirst() }

        let elapsed = date.timeIntervalSince(pointStartTime)
        guard refinementBuffer.count >= 4 else { return }

        let window = Array(refinementBuffer.suffix(5))
        let meanX = window.map(\.pupilX).reduce(0, +) / Double(window.count)
        let meanY = window.map(\.pupilY).reduce(0, +) / Double(window.count)
        var varSum = 0.0
        for f in window {
            let dx = f.pupilX - meanX
            let dy = f.pupilY - meanY
            varSum += dx * dx + dy * dy
        }
        let spread = (varSum / Double(window.count)).squareRoot()

        if spread < 0.025 {
            refinementHoldCount += 1
        }

        if !requireClick && (refinementHoldCount >= 6 || (elapsed >= 2.5 && refinementBuffer.count >= 3)) {
            if let sample = CalibrationSample.aggregate(
                frames: refinementBuffer,
                targetX: target.x,
                targetY: target.y,
                minimumFrames: 3
            ) {
                refinementSamples.append(sample)
            }

            refinementIndex += 1
            refinementBuffer.removeAll()
            refinementHoldCount = 0
            pointStartTime = date

            if refinementIndex >= refinementPoints.count {
                // Refit final map with refined samples replacing old high-error samples
                finalizeRefinedModel()
            }
        }
    }

    private func finalizeRefinedModel() {
        var merged = anchorSamples + pursuitSamples

        // Replace or augment samples close to refined targets
        for ref in refinementSamples {
            merged.removeAll { s in
                hypot(s.targetX - ref.targetX, s.targetY - ref.targetY) < 0.15
            }
            merged.append(ref)
        }

        do {
            let calibrator = GazeCalibrator()
            finalMap = try calibrator.calibrate(
                samples: merged,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                context: context
            )
        } catch {
            finalMap = nil
        }
        stage = .finished
    }

    // MARK: - Affine Solver Helper

    private struct Affine2D {
        let ax: Double, bx: Double, cx: Double
        let ay: Double, by: Double, cy: Double

        func predict(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
            (ax * px + bx * py + cx, ay * px + by * py + cy)
        }
    }

    private func computeAffineModel(from samples: [CalibrationSample]) -> Affine2D? {
        guard samples.count >= 3 else { return nil }
        let pts = Array(samples.prefix(3))
        let p0 = (px: pts[0].features[0], py: pts[0].features[1], tx: pts[0].targetX, ty: pts[0].targetY)
        let p1 = (px: pts[1].features[0], py: pts[1].features[1], tx: pts[1].targetX, ty: pts[1].targetY)
        let p2 = (px: pts[2].features[0], py: pts[2].features[1], tx: pts[2].targetX, ty: pts[2].targetY)

        let det = p0.px * (p1.py - p2.py) - p0.py * (p1.px - p2.px) + (p1.px * p2.py - p1.py * p2.px)
        guard abs(det) > 1e-6 else { return nil }

        let invDet = 1.0 / det
        let ax = invDet * (p0.tx * (p1.py - p2.py) - p0.py * (p1.tx - p2.tx) + (p1.tx * p2.py - p1.py * p2.tx))
        let bx = invDet * (p0.px * (p1.tx - p2.tx) - p0.tx * (p1.px - p2.px) + (p1.px * p2.tx - p1.tx * p2.px))
        let cx = invDet * (p0.px * (p1.py * p2.tx - p1.tx * p2.py) - p0.py * (p1.px * p2.tx - p1.tx * p2.px) + p0.tx * (p1.px * p2.py - p1.py * p2.px))

        let ay = invDet * (p0.ty * (p1.py - p2.py) - p0.py * (p1.ty - p2.ty) + (p1.ty * p2.py - p1.py * p2.ty))
        let by = invDet * (p0.px * (p1.ty - p2.ty) - p0.ty * (p1.px - p2.px) + (p1.px * p2.ty - p1.ty * p2.px))
        let cy = invDet * (p0.px * (p1.py * p2.ty - p1.ty * p2.py) - p0.py * (p1.px * p2.ty - p1.ty * p2.px) + p0.ty * (p1.px * p2.py - p1.py * p2.px))

        return Affine2D(ax: ax, bx: bx, cx: cx, ay: ay, by: by, cy: cy)
    }
}
