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
    /// measured features were stable while they held the target.
    public func isTrustworthy(maximumSpread: Double = 0.09, minimumFrames: Int = 8) -> Bool {
        frameCount >= minimumFrames && featureSpread <= maximumSpread
    }
}
