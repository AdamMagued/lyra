import Foundation

/// Raw, uncalibrated measurements extracted from a single camera frame.
///
/// This is the *input* to calibration, not a guess at where the user is looking.
/// The previous design collapsed these measurements into a hand-tuned "gaze" point
/// before calibration saw them, which meant calibration was fitting a curve to a
/// fudge factor. Here the raw signals survive intact so the calibration fit can
/// discover the real mapping — including sign, scale, and interaction terms.
///
/// Coordinate conventions (constrained by Vision, see `FaceFeatureExtractor`):
/// - Everything comes from Vision's face-relative normalized space, origin bottom-left.
/// - `pupilX` increases towards the user's right *in the camera image*, which is the
///   user's left in the real world for an unmirrored front camera. This is deliberate:
///   we do not correct handedness here, because the regression will learn it and a
///   hard-coded flip is exactly the kind of guess that made the old pipeline fail.
public struct GazeFeatures: Sendable, Equatable, Codable {
    /// Bump when the meaning or ordering of `vector` changes. Saved calibrations
    /// carry the version they were fit against and are discarded on mismatch.
    public static let schemaVersion: Int = 3

    /// Horizontal pupil position averaged across both eyes, normalised within the
    /// eye-corner axis so it is invariant to head roll. Roughly 0...1.
    public let pupilX: Double

    /// Vertical pupil position averaged across both eyes, normalised by eye opening.
    /// Roughly 0...1.
    public let pupilY: Double

    /// Head rotation in radians, from Vision's face pose estimate.
    public let yaw: Double
    public let pitch: Double
    public let roll: Double

    /// Face centre in camera-image space, normalised 0...1, origin bottom-left.
    /// Captures head *translation*, which moves the whole eyeball relative to the screen.
    public let faceX: Double
    public let faceY: Double

    /// Normalised inter-pupil distance. Shrinks as the user leans away, so it is the
    /// primary depth cue used to compensate for posture changes.
    public let iod: Double

    /// Face bounding-box width in camera-image space. A second, coarser depth cue that
    /// stays valid when the pupils are momentarily lost.
    public let faceWidth: Double

    /// 0 = closed, 1 = fully open. Used to reject blinks, which otherwise inject
    /// large garbage samples into both calibration and live tracking.
    public let eyeOpenness: Double

    /// Detector confidence in the underlying face observation, 0...1.
    public let confidence: Double

    public let timestamp: Date

    public init(
        pupilX: Double,
        pupilY: Double,
        yaw: Double,
        pitch: Double,
        roll: Double,
        faceX: Double,
        faceY: Double,
        iod: Double,
        faceWidth: Double,
        eyeOpenness: Double,
        confidence: Double,
        timestamp: Date = Date()
    ) {
        self.pupilX = pupilX
        self.pupilY = pupilY
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.faceX = faceX
        self.faceY = faceY
        self.iod = iod
        self.faceWidth = faceWidth
        self.eyeOpenness = eyeOpenness
        self.confidence = confidence
        self.timestamp = timestamp
    }

    /// Ordered feature vector consumed by the calibration regression.
    ///
    /// Order is load-bearing: it is persisted inside `CalibrationMap` via
    /// `schemaVersion`, and the first `GazeCalibrator.primaryFeatureCount` entries
    /// receive the full polynomial expansion.
    public var vector: [Double] {
        [pupilX, pupilY, yaw, pitch, roll, faceX, faceY, iod, faceWidth]
    }

    public static var featureCount: Int { 9 }

    /// Human-readable names, index-aligned with `vector`. Used in diagnostics.
    public static let featureNames = [
        "pupilX", "pupilY", "yaw", "pitch", "roll", "faceX", "faceY", "iod", "faceWidth"
    ]

    /// Whether this sample is fit to be used for calibration or live tracking.
    ///
    /// Blinks are the single largest source of corrupted samples in webcam gaze
    /// tracking, so they are rejected here rather than filtered downstream.
    public var isUsable: Bool {
        confidence > 0.2 && eyeOpenness > 0.55 && iod > 0.01
    }

    /// Returns a copy with the timestamp replaced.
    public func retimestamped(_ date: Date) -> GazeFeatures {
        GazeFeatures(
            pupilX: pupilX, pupilY: pupilY,
            yaw: yaw, pitch: pitch, roll: roll,
            faceX: faceX, faceY: faceY,
            iod: iod, faceWidth: faceWidth,
            eyeOpenness: eyeOpenness,
            confidence: confidence,
            timestamp: date
        )
    }

    /// Returns a copy of these features with pupil positions and head pose compensated
    /// relative to a reference baseline head posture.
    public func compensated(relativeTo baseline: CalibrationMap.HeadBaseline) -> GazeFeatures {
        let comp = baseline.compensate(vector: vector)
        return GazeFeatures(
            pupilX: comp[0],
            pupilY: comp[1],
            yaw: comp[2],
            pitch: comp[3],
            roll: comp[4],
            faceX: comp[5],
            faceY: comp[6],
            iod: comp[7],
            faceWidth: comp[8],
            eyeOpenness: eyeOpenness,
            confidence: confidence,
            timestamp: timestamp
        )
    }
}
