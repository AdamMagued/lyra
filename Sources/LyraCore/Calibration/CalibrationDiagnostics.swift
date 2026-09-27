import Foundation

/// Summarises what a calibration run actually measured.
///
/// A calibration reports one number — its average error — and that number cannot say
/// *why* it is bad. The two causes need opposite fixes, so a bad error on its own leaves
/// no way to act:
///
/// - **The features do not move with gaze.** If the pupil barely shifts across the whole
///   pattern, there is nothing for the fit to learn and no amount of extra points,
///   curvature or tuning will help. The fix is upstream, in measurement.
/// - **The features move, but noisily**, and the fit chases the noise. The fix is
///   downstream: fewer terms, stronger regularisation.
///
/// These summaries separate the two. A feature with a small range, or one whose
/// correlation with the target is near zero, is not carrying gaze direction no matter
/// how good the fit is.
public enum CalibrationDiagnostics {

    public struct FeatureSummary: Codable, Sendable, Equatable {
        public let name: String
        public let minimum: Double
        public let maximum: Double
        public let standardDeviation: Double
        /// Pearson correlation with the target's screen position, -1...1. Zero when
        /// either quantity never varied, which is the honest answer rather than a
        /// division by zero dressed up as a number.
        public let correlationWithX: Double
        public let correlationWithY: Double

        public var range: Double { maximum - minimum }

        /// The largest correlation this feature has with either screen axis, which is
        /// the quickest read on whether it carries gaze at all.
        public var strongestCorrelation: Double { max(abs(correlationWithX), abs(correlationWithY)) }
    }

    public static func summarise(_ samples: [CalibrationSample]) -> [FeatureSummary] {
        guard samples.count >= 2 else { return [] }

        let xs = samples.map(\.targetX)
        let ys = samples.map(\.targetY)

        return (0..<GazeFeatures.featureCount).map { index in
            let values = samples.map { sample -> Double in
                index < sample.features.count ? sample.features[index] : 0
            }
            return FeatureSummary(
                name: index < GazeFeatures.featureNames.count
                    ? GazeFeatures.featureNames[index]
                    : "feature\(index)",
                minimum: values.min() ?? 0,
                maximum: values.max() ?? 0,
                standardDeviation: standardDeviation(of: values),
                correlationWithX: correlation(values, xs),
                correlationWithY: correlation(values, ys)
            )
        }
    }

    static func standardDeviation(of values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Pearson correlation, or zero if either input is constant.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count >= 2 else { return 0 }
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)

        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for i in a.indices {
            let da = a[i] - meanA
            let db = b[i] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }

        guard varianceA > 1e-15, varianceB > 1e-15 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }
}
