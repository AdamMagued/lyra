import Foundation

/// Calibration driven by clicks instead of by staring and waiting.
///
/// The stare-based capture has to *infer* that the user was looking at the dot, and it
/// spends a state machine — settling, holding, stability gating, retrying, an expiry
/// timeout — making that inference safe. A click needs no inference. It is a deliberate
/// act at a known screen position, so it labels the eye measurement with ground truth
/// rather than with an assumption, and it removes the timing race completely: there is
/// no window during which the user was supposed to have arrived at the target.
///
/// The shape follows WebGazer's interactive calibration, which is the one idea in it
/// worth taking. Several clicks per target give the fit repeated, independently labelled
/// observations of the same screen position, and a click that lands nowhere near the dot
/// is rejected rather than silently teaching the model something false.
///
/// Hardware-free and event-driven, so the whole thing is unit testable.
public final class ClickCalibration {

    /// What the UI needs to draw.
    public struct Progress: Sendable, Equatable {
        public let pointIndex: Int
        public let totalPoints: Int
        /// Normalised position of the dot being shown, origin top-left.
        public let pointX: Double
        public let pointY: Double
        public let clicksForPoint: Int
        public let clicksPerPoint: Int
        public let samplesCollected: Int
        public let isFinished: Bool
    }

    private let pattern: CalibrationPattern
    public let clicksPerPoint: Int

    /// How many frames are kept to label a click with.
    ///
    /// Short on purpose. The window has to cover the eye *at the moment of the click*, so
    /// a long buffer would average in wherever the user was looking beforehand — which is
    /// precisely the failure the stare-based capture kept making.
    private let frameBufferLimit: Int

    private let minimumFrames: Int

    /// How far from the dot a click may land and still be counted as a label for it,
    /// in screen points. Generous, because the user's *aim* is not what is being
    /// measured — the gaze is. This only rejects clicks that were plainly at something
    /// else.
    private let clickTolerancePoints: Double

    private var frames: [GazeFeatures] = []
    private var position = 0
    private var clicksForPoint = 0

    public private(set) var samples: [CalibrationSample] = []

    /// Clicks that landed nowhere near the current dot.
    public private(set) var rejectedClicks = 0

    /// Clicks on the dot that had no trustworthy frames behind them.
    public private(set) var droppedClicks = 0

    public init(
        pattern: CalibrationPattern = .click,
        clicksPerPoint: Int = 4,
        frameBufferLimit: Int = 20,
        minimumFrames: Int = 5,
        clickTolerancePoints: Double = 110
    ) {
        self.pattern = pattern
        self.clicksPerPoint = max(clicksPerPoint, 1)
        self.frameBufferLimit = max(frameBufferLimit, minimumFrames)
        self.minimumFrames = max(minimumFrames, 2)
        self.clickTolerancePoints = clickTolerancePoints
    }

    // MARK: - State

    public var totalPoints: Int { pattern.points.count }
    public var isFinished: Bool { position >= pattern.points.count }
    public var totalClicks: Int { totalPoints * clicksPerPoint }

    public var currentPoint: CalibrationPattern.Point? {
        guard position < pattern.points.count else { return nil }
        return pattern.points[position]
    }

    public var progress: Progress {
        Progress(
            pointIndex: min(position, pattern.points.count),
            totalPoints: totalPoints,
            pointX: currentPoint?.x ?? 0.5,
            pointY: currentPoint?.y ?? 0.5,
            clicksForPoint: clicksForPoint,
            clicksPerPoint: clicksPerPoint,
            samplesCollected: samples.count,
            isFinished: isFinished
        )
    }

    // MARK: - Input

    public func start() {
        frames.removeAll()
        position = 0
        clicksForPoint = 0
        samples.removeAll()
        rejectedClicks = 0
        droppedClicks = 0
    }

    /// Buffers one frame, to be used as the label for a click that follows it.
    public func observe(features: GazeFeatures) {
        guard !isFinished else { return }
        frames.append(features)
        if frames.count > frameBufferLimit { frames.removeFirst() }
    }

    /// Records a click, if it is a usable label for the current dot.
    ///
    /// - Parameters:
    ///   - point: where the click landed, normalised 0...1, origin top-left.
    ///   - screenSize: needed to judge the distance in real screen points, because a
    ///     normalised tolerance would be far stricter vertically than horizontally.
    /// - Returns: whether the click counted towards the current dot.
    @discardableResult
    public func registerClick(
        atNormalized point: (x: Double, y: Double),
        screenSize: LyraSize
    ) -> Bool {
        guard let target = currentPoint else { return false }

        let dx = (point.x - target.x) * screenSize.width
        let dy = (point.y - target.y) * screenSize.height
        guard (dx * dx + dy * dy).squareRoot() <= clickTolerancePoints else {
            rejectedClicks += 1
            return false
        }

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
        clicksForPoint += 1

        if clicksForPoint >= clicksPerPoint {
            position += 1
            clicksForPoint = 0
            // The buffer is not carried across dots: the first frame after the dot moves
            // is of an eye that is still travelling towards the new position.
            frames.removeAll()
        }

        return true
    }
}
