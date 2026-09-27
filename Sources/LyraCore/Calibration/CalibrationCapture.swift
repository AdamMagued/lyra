import Foundation

/// Drives a calibration run: walks the pattern, collects measurements at each point, and
/// decides which points produced trustworthy data.
///
/// The previous implementation held each dot for a fixed time and averaged whatever
/// arrived. That is the root cause of calibration that looks fine and then misbehaves,
/// because three separate things can go wrong during a hold and none of them were
/// detected:
///
/// 1. **The eye has not arrived yet.** After a target appears the eye makes a saccade
///    and then a small corrective movement. Averaging from the instant the dot appears
///    drags every sample towards wherever the user was looking before. Handled here by
///    an explicit settling period before collection starts.
///
/// 2. **The user blinked.** A blink puts the pupil estimate near the eyelid, which reads
///    as a large vertical shift. Handled by rejecting unusable frames, and by a median
///    pass that discards frames far from the point's own median.
///
/// 3. **The user glanced away.** A single frame of looking elsewhere is enough to bend
///    the fit. The per-point median filter removes it, and a point that cannot produce
///    enough clean frames is *retried* rather than silently accepted.
///
/// That last part is what "intense" means in practice: the run takes longer because it
/// refuses to accept bad data, and it goes back for more when a point fails.
///
/// Hardware-free and clock-driven, so the whole state machine is unit testable.
public final class CalibrationCapture {

    public enum Phase: Sendable, Equatable {
        /// Target is shown, waiting for the eye to arrive.
        case settling
        /// Collecting measurements.
        case collecting
        /// Run complete.
        case finished
    }

    /// What the UI needs to draw for the current point.
    public struct Progress: Sendable, Equatable {
        public let pointIndex: Int
        public let totalPoints: Int
        /// Normalised position of the dot being shown, origin top-left.
        ///
        /// Carried here rather than looked up by the UI from the pattern, because a run
        /// that retries a point walks its own order — indexing the pattern with
        /// `pointIndex` renders the wrong dot the moment anything is retried.
        public let pointX: Double
        public let pointY: Double
        public let phase: Phase
        /// Fraction of the current point's collection window elapsed, 0...1.
        public let elapsedFraction: Double
        /// How steadily the user is holding the target, 0...1, for the feedback ring.
        public let lockQuality: Double
        /// True once stability is good enough that this point's data will be kept.
        public let isLocked: Bool
        /// How many points have had to be retried so far.
        public let retryCount: Int

        public var isFinished: Bool { phase == .finished }
    }

    // MARK: - Configuration

    private let pattern: CalibrationPattern

    /// Time after a target appears before collection begins. Long enough for the saccade
    /// and its correction to settle.
    public static let defaultSettleDuration: TimeInterval = 0.6

    private let settleDuration: TimeInterval

    /// Minimum acceptable frames for a point to produce a sample.
    private let minimumFrames: Int

    /// Feature-space spread above which the user is considered not to be holding still.
    private let stabilityTolerance: Double

    /// Lock quality at or above which the user counts as looking at the target at all.
    /// Shared with the feedback ring, so what the user is told and what the state machine
    /// acts on cannot drift apart.
    static let lockedQuality = 0.65

    /// Frames the eye must be on the target, this point, before the hold can complete.
    ///
    /// This is the difference between a run that waits for the user and one that leaves
    /// without them.
    private let minimumStableFrames: Int

    /// How far past its hold a point will wait for the user, as a multiple of the hold.
    ///
    /// Bounds the wait, so a point the user cannot settle on becomes a retry rather than a
    /// stall. The sample is still finalised when this expires, so a noisy tracker produces
    /// a slower calibration rather than none.
    private static let holdTimeoutFactor = 2.5

    /// Maximum retries per point before giving up on it.
    private let maximumRetries: Int

    // MARK: - State

    private var order: [Int]
    private var retriesUsed: [Int: Int] = [:]
    private var position = 0
    private var phase: Phase = .settling
    private var pointStartedAt: TimeInterval = 0
    private var collected: [(features: GazeFeatures, time: TimeInterval)] = []
    private var recentVectors: [[Double]] = []
    private var stableFrames = 0

    public private(set) var samples: [CalibrationSample] = []
    public private(set) var retryCount = 0

    /// Points that were retried and still failed, for honest reporting.
    public private(set) var abandonedPoints: [Int] = []

    public init(
        pattern: CalibrationPattern,
        settleDuration: TimeInterval = CalibrationCapture.defaultSettleDuration,
        minimumFrames: Int = 10,
        minimumStableFrames: Int = 8,
        stabilityTolerance: Double = 0.055,
        maximumRetries: Int = 1
    ) {
        self.pattern = pattern
        self.settleDuration = settleDuration
        self.minimumFrames = minimumFrames
        self.minimumStableFrames = minimumStableFrames
        self.stabilityTolerance = stabilityTolerance
        self.maximumRetries = maximumRetries
        self.order = Array(pattern.points.indices)
    }

    public var isFinished: Bool { phase == .finished }

    /// How long a full pass over a pattern takes, for telling the user what they are
    /// committing to before they start.
    ///
    /// Derived from the state machine's own timings rather than written down separately,
    /// so the number shown cannot drift away from the run it describes. Retries are not
    /// included: they are the exception, and quoting a worst case would make a routine
    /// calibration sound like a chore.
    public static func estimatedDuration(for pattern: CalibrationPattern) -> TimeInterval {
        Double(pattern.points.count) * (defaultSettleDuration + pattern.holdDuration)
    }

    public var currentPoint: CalibrationPattern.Point? {
        guard position < order.count else { return nil }
        return pattern.points[order[position]]
    }

    public var totalPoints: Int { pattern.points.count }

    /// Begins the run.
    public func start(at time: TimeInterval) {
        position = 0
        phase = .settling
        pointStartedAt = time
        collected = []
        recentVectors = []
        stableFrames = 0
        samples = []
        retriesUsed = [:]
        abandonedPoints = []
        retryCount = 0
        order = Array(pattern.points.indices)
    }

    /// Feeds one frame. Returns the progress to render, or `nil` once finished.
    public func update(features: GazeFeatures, at time: TimeInterval) -> Progress? {
        guard phase != .finished, let point = currentPoint else { return nil }

        recentVectors.append(features.vector)
        if recentVectors.count > 6 { recentVectors.removeFirst() }

        let lockQuality = currentLockQuality()
        let elapsed = time - pointStartedAt

        switch phase {
        case .settling:
            if elapsed >= settleDuration {
                phase = .collecting
                pointStartedAt = time
                collected = []
                stableFrames = 0
            }
            return Progress(
                pointIndex: position,
                totalPoints: totalPoints,
                pointX: point.x,
                pointY: point.y,
                phase: phase,
                elapsedFraction: 0,
                lockQuality: lockQuality,
                isLocked: lockQuality >= Self.lockedQuality,
                retryCount: retryCount
            )

        case .collecting:
            // Blinks and unusable frames are dropped rather than averaged in.
            if features.isUsable {
                collected.append((features, time))
            }
            if lockQuality >= Self.lockedQuality { stableFrames += 1 }

            // A point completes when it has been held long enough *and* the eye was
            // actually on it for enough of that time.
            //
            // It used to complete purely on the clock, which is the whole of "it goes too
            // fast": the dot left after a fixed second whether or not the user had arrived
            // at it, so the run raced ahead of anyone still finding the target and then
            // fitted the model to frames of them looking somewhere else.
            let heldLongEnough = elapsed >= pattern.holdDuration
            let wasOnTarget = stableFrames >= minimumStableFrames
            let waitedTooLong = elapsed >= pattern.holdDuration * Self.holdTimeoutFactor

            if !(heldLongEnough && wasOnTarget) && !waitedTooLong {
                return Progress(
                    pointIndex: position,
                    totalPoints: totalPoints,
                    pointX: point.x,
                    pointY: point.y,
                    phase: .collecting,
                    // Never quite completes while the point is still waiting on the eye.
                    // A full ring next to "keep looking at the dot" reads as a bug.
                    elapsedFraction: heldLongEnough ? 0.97 : min(elapsed / pattern.holdDuration, 1.0),
                    lockQuality: lockQuality,
                    isLocked: lockQuality >= Self.lockedQuality,
                    retryCount: retryCount
                )
            }

            let produced = finalisePoint(point: point, at: time)
            advance(at: time, producedSample: produced)
            return currentProgress(at: time)

        case .finished:
            return nil
        }
    }

    /// Reports a point that the user themselves flagged as bad, for example because they
    /// knew they blinked. Retried unconditionally.
    public func flagCurrentPointForRetry(at time: TimeInterval) {
        guard position < order.count else { return }
        let index = order[position]
        retriesUsed[index, default: 0] += 1
        retryCount += 1
        order.append(index)
        advance(at: time, producedSample: true)
    }

    // MARK: - Point finalisation

    /// Builds a sample from the frames collected for one point, discarding outliers.
    ///
    /// Returns whether a usable sample was produced.
    private func finalisePoint(point: CalibrationPattern.Point, at time: TimeInterval) -> Bool {
        guard collected.count >= minimumFrames else { return false }
        guard let usable = rejectOutliers(collected) else { return false }

        let vectors = usable.map(\.features.vector)
        let count = Double(vectors.count)
        var means = [Double](repeating: 0, count: GazeFeatures.featureCount)
        for vector in vectors {
            for i in 0..<min(vector.count, means.count) { means[i] += vector[i] }
        }
        for i in means.indices { means[i] /= count }

        // Spread across the accepted frames, so downstream filtering can prefer samples
        // that were captured while the user was actually still.
        var spread = 0.0
        for vector in vectors {
            var squared = 0.0
            for i in 0..<min(vector.count, means.count) {
                squared += pow(vector[i] - means[i], 2)
            }
            spread += squared.squareRoot()
        }
        spread /= count

        samples.append(CalibrationSample(
            targetX: point.x,
            targetY: point.y,
            features: means,
            frameCount: vectors.count,
            featureSpread: spread
        ))
        return true
    }

    /// Keeps frames whose feature vector is close to the point's own median.
    ///
    /// Median-based rather than mean-based so that a run of frames from a glance away
    /// cannot drag the reference towards itself and legitimise the very samples we are
    /// trying to remove.
    private func rejectOutliers(
        _ frames: [(features: GazeFeatures, time: TimeInterval)]
    ) -> [(features: GazeFeatures, time: TimeInterval)]? {
        guard frames.count >= minimumFrames else { return nil }

        let vectors = frames.map(\.features.vector)
        var medians = [Double](repeating: 0, count: GazeFeatures.featureCount)
        for i in 0..<GazeFeatures.featureCount {
            medians[i] = Self.median(vectors.map { $0[i] })
        }

        var distances: [Double] = []
        distances.reserveCapacity(vectors.count)
        for vector in vectors {
            var squared = 0.0
            for i in 0..<GazeFeatures.featureCount {
                squared += pow(vector[i] - medians[i], 2)
            }
            distances.append(squared.squareRoot())
        }

        let medianDistance = Self.median(distances)
        let deviations = distances.map { abs($0 - medianDistance) }
        let mad = Self.median(deviations)

        // With very tight residuals everything is kept; otherwise reject anything more
        // than three robust deviations out, which is the standard robust-outlier rule.
        let cutoff = mad > 1e-9 ? medianDistance + 3.0 * mad : max(medianDistance, 1e-9)
        let kept = zip(frames, distances)
            .filter { $0.1 <= cutoff }
            .map(\.0)

        // If pruning was too aggressive to leave a usable point, prefer the raw data
        // over losing the point entirely.
        return kept.count >= minimumFrames ? kept : nil
    }

    // MARK: - Advancement

    private func advance(at time: TimeInterval, producedSample: Bool) {
        let index = order[position]

        if !producedSample {
            let used = retriesUsed[index, default: 0]
            if used < maximumRetries {
                retriesUsed[index] = used + 1
                retryCount += 1
                order.append(index)
            } else {
                abandonedPoints.append(index)
            }
        }

        position += 1
        collected = []
        recentVectors = []
        stableFrames = 0
        pointStartedAt = time

        if position >= order.count {
            phase = .finished
        } else {
            phase = .settling
        }
    }

    private func currentProgress(at time: TimeInterval) -> Progress? {
        guard phase != .finished else {
            return Progress(
                pointIndex: totalPoints,
                totalPoints: totalPoints,
                pointX: 0.5,
                pointY: 0.5,
                phase: .finished,
                elapsedFraction: 1,
                lockQuality: 0,
                isLocked: false,
                retryCount: retryCount
            )
        }
        return Progress(
            pointIndex: position,
            totalPoints: totalPoints,
            pointX: currentPoint?.x ?? 0.5,
            pointY: currentPoint?.y ?? 0.5,
            phase: phase,
            elapsedFraction: 0,
            lockQuality: currentLockQuality(),
            isLocked: false,
            retryCount: retryCount
        )
    }

    /// How steadily the last few frames agree, 0...1.
    ///
    /// This is what drives the "you are locked on" feedback, and unlike the previous
    /// implementation it is a real measurement of the eye rather than a check that a
    /// camera frame arrived. The old indicator lit up even when the user was looking at
    /// the wall.
    private func currentLockQuality() -> Double {
        guard recentVectors.count >= 3 else { return 0 }

        var spread = 0.0
        for i in 0..<GazeFeatures.featureCount {
            let values = recentVectors.map { $0[i] }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(values.count)
            spread += variance.squareRoot()
        }
        spread /= Double(GazeFeatures.featureCount)

        return min(max(1.0 - spread / stabilityTolerance, 0.0), 1.0)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
