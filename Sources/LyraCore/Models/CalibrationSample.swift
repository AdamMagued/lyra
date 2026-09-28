import Foundation

/// One calibration observation: the feature vector measured while the user was
/// looking at a known screen location.
///
/// A sample is the *mean* of many camera frames, not a single frame. Averaging is
/// what turns Vision's noisy per-frame pupil estimate into something a regression
/// can fit; the per-frame spread is kept so outliers can be identified later.
public struct CalibrationSample: Sendable, Equatable, Codable {
    /// The screen location the user was asked to look at, normalised 0...1,
    /// origin top-left (screen convention).
    public let targetX: Double
    public let targetY: Double

    /// Mean feature vector across the frames accepted for this point.
    public let features: [Double]

    /// How many camera frames contributed.
    public let frameCount: Int

    /// Per-feature standard deviation across contributing frames. Large values mean
    /// the user was not holding still, and the sample is correspondingly less trusted.
    public let featureSpread: Double

    /// Feature schema this sample was captured under.
    public let schemaVersion: Int

    public init(
        targetX: Double,
        targetY: Double,
        features: [Double],
        frameCount: Int,
        featureSpread: Double,
        schemaVersion: Int = GazeFeatures.schemaVersion
    ) {
        self.targetX = targetX
        self.targetY = targetY
        self.features = features
        self.frameCount = frameCount
        self.featureSpread = featureSpread
        self.schemaVersion = schemaVersion
    }

    /// A sample is trustworthy only if enough frames contributed and the user's
    /// measured features were stable while they held or tracked the target.
    public func isTrustworthy(maximumSpread: Double = 0.14, minimumFrames: Int = 3) -> Bool {
        frameCount >= minimumFrames && featureSpread <= maximumSpread
    }

    /// Averages a run of frames into one sample, rejecting frames that disagree with the
    /// bulk of the run.
    ///
    /// Shared by both capture strategies — staring and clicking — because the rejection
    /// is the part that matters and the part that is easy to get subtly wrong. A single
    /// glance away inside the window would otherwise be averaged straight into the label,
    /// and the fit has no way to know the label is a lie.
    ///
    /// Returns `nil` when too few frames survive, which the caller must treat as a failed
    /// measurement rather than as a sample of nothing.
    public static func aggregate(
        frames: [GazeFeatures],
        targetX: Double,
        targetY: Double,
        minimumFrames: Int = 8
    ) -> CalibrationSample? {
        guard let kept = rejectOutliers(frames.filter(\.isUsable).map(\.vector), minimumFrames: minimumFrames) else {
            return nil
        }

        let count = Double(kept.count)
        var means = [Double](repeating: 0, count: GazeFeatures.featureCount)
        for vector in kept {
            for i in 0..<min(vector.count, means.count) { means[i] += vector[i] }
        }
        for i in means.indices { means[i] /= count }

        // Spread across the accepted frames, so downstream filtering can prefer samples
        // that were captured while the user was actually still.
        var spread = 0.0
        for vector in kept {
            var squared = 0.0
            for i in 0..<min(vector.count, means.count) {
                squared += pow(vector[i] - means[i], 2)
            }
            spread += squared.squareRoot()
        }
        spread /= count

        return CalibrationSample(
            targetX: targetX,
            targetY: targetY,
            features: means,
            frameCount: kept.count,
            featureSpread: spread
        )
    }

    /// Keeps vectors whose distance from the run's own median is within three robust
    /// deviations.
    ///
    /// Median-based rather than mean-based so that a run of frames from a glance away
    /// cannot drag the reference towards itself and legitimise the very samples we are
    /// trying to remove.
    static func rejectOutliers(_ vectors: [[Double]], minimumFrames: Int) -> [[Double]]? {
        guard vectors.count >= minimumFrames else { return nil }

        var medians = [Double](repeating: 0, count: GazeFeatures.featureCount)
        for i in 0..<GazeFeatures.featureCount {
            medians[i] = median(vectors.map { $0[i] })
        }

        let distances = vectors.map { vector -> Double in
            var squared = 0.0
            for i in 0..<GazeFeatures.featureCount {
                squared += pow(vector[i] - medians[i], 2)
            }
            return squared.squareRoot()
        }

        let medianDistance = median(distances)
        let mad = median(distances.map { abs($0 - medianDistance) })

        // With very tight residuals everything is kept; otherwise reject anything more
        // than three robust deviations out, which is the standard robust-outlier rule.
        let cutoff = mad > 1e-9 ? medianDistance + 3.0 * mad : max(medianDistance, 1e-9)
        let kept = zip(vectors, distances).filter { $0.1 <= cutoff }.map(\.0)

        // If pruning was too aggressive to leave a usable run, prefer the raw data over
        // losing the measurement entirely.
        return kept.count >= minimumFrames ? kept : nil
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
