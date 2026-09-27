import Foundation

/// Maps raw camera features to a screen position.
///
/// This is the whole point of calibration, and it is the piece the previous
/// implementation got structurally wrong. It used to fit a polynomial from an
/// already-hand-tuned "gaze" estimate to the screen, which is fitting a curve to a
/// guess. Here the polynomial is fit directly from the raw measured features to the
/// screen, so the regression *is* the gaze model rather than a correction on top of
/// one.
///
/// Two independent polynomials are fit — one per screen axis — because horizontal and
/// vertical gaze have genuinely different dynamics (vertical eye rotation has roughly
/// half the range of horizontal, and is heavily confounded by eyelid occlusion).
public struct CalibrationMap: Codable, Sendable, Equatable {

    /// Feature schema this map was fit against. A mismatch means the features changed
    /// meaning, and the map must be discarded rather than silently mispredicting.
    public let schemaVersion: Int

    public let isCalibrated: Bool

    /// Cross-validated error in normalised screen units (0...1). This is measured on
    /// held-out samples, so unlike the previous implementation it is a real estimate
    /// of generalisation error rather than a training residual.
    public let validationErrorNormalized: Double

    /// The same error expressed in pixels, for display.
    public let validationErrorPixels: Double

    /// Number of calibration points that survived quality filtering.
    public let pointCount: Int

    /// Per-point residuals in normalised units, so the UI can show which screen
    /// regions calibrated badly.
    public let residuals: [CalibrationResidual]

    let xModel: RidgeRegression.Model
    let yModel: RidgeRegression.Model
    let basis: PolynomialBasis

    /// What this map was fitted against.
    ///
    /// A calibration is not a property of the user, it is a property of the *setup*: the
    /// geometry between a particular camera and a particular screen, and how that user's
    /// eye appears from that camera. Move the laptop, plug it into another display, close
    /// the lid so a different camera takes over, and the fitted polynomial is describing a
    /// situation that no longer exists — while continuing to produce confident, wrong
    /// screen positions.
    ///
    /// Recording the setup is what lets Lyra notice. It is optional so that a map saved
    /// before this existed still loads.
    public let context: CalibrationContext?

    public struct CalibrationContext: Codable, Sendable, Equatable {
        /// `CGDirectDisplayID` of the screen that was calibrated.
        public let displayID: UInt32?
        /// `AVCaptureDevice.uniqueID` of the camera that was used.
        public let cameraID: String?
        /// Screen size in points at the time, so a resolution change is visible even when
        /// the display is the same panel.
        public let screenSize: LyraSize?

        public init(displayID: UInt32? = nil, cameraID: String? = nil, screenSize: LyraSize? = nil) {
            self.displayID = displayID
            self.cameraID = cameraID
            self.screenSize = screenSize
        }

        /// Whether this describes the same setup as another.
        ///
        /// Only fields present in *both* are compared. A dimension the system did not
        /// report on one side is not evidence of a change, and treating it as one would
        /// demand a recalibration every launch on a machine that does not report it.
        public func matches(_ other: CalibrationContext) -> Bool {
            if let a = displayID, let b = other.displayID, a != b { return false }
            if let a = cameraID, let b = other.cameraID, a != b { return false }
            if let a = screenSize, let b = other.screenSize, a != b { return false }
            return true
        }

        /// Names what changed, for the message the user sees. `nil` when nothing did.
        public func difference(from other: CalibrationContext) -> String? {
            if let a = displayID, let b = other.displayID, a != b {
                return "a different display"
            }
            if let a = cameraID, let b = other.cameraID, a != b {
                return "a different camera"
            }
            if let a = screenSize, let b = other.screenSize, a != b {
                return "a screen resolution change"
            }
            return nil
        }
    }

    /// Whether this map still describes the setup it is about to be used in.
    ///
    /// A map with no recorded context is accepted: the only way to have one is to have
    /// calibrated before the context was recorded, and refusing it would demand a
    /// recalibration the user has no reason to expect.
    public func isUsable(with context: CalibrationContext) -> Bool {
        guard let own = self.context else { return true }
        return own.matches(context)
    }

    public struct CalibrationResidual: Codable, Sendable, Equatable {
        public let targetX: Double
        public let targetY: Double
        /// Distance between predicted and intended target, normalised.
        public let error: Double

        public init(targetX: Double, targetY: Double, error: Double) {
            self.targetX = targetX
            self.targetY = targetY
            self.error = error
        }
    }

    /// A map that does nothing. Used when no calibration exists yet; the caller is
    /// expected to check `isCalibrated` and refuse to drive the cursor through it.
    public static let identity = CalibrationMap(
        schemaVersion: GazeFeatures.schemaVersion,
        isCalibrated: false,
        validationErrorNormalized: .infinity,
        validationErrorPixels: .infinity,
        pointCount: 0,
        residuals: [],
        xModel: RidgeRegression.Model(coefficients: [0.5], means: [], scales: []),
        yModel: RidgeRegression.Model(coefficients: [0.5], means: [], scales: []),
        basis: .default,
        context: nil
    )

    init(
        schemaVersion: Int,
        isCalibrated: Bool,
        validationErrorNormalized: Double,
        validationErrorPixels: Double,
        pointCount: Int,
        residuals: [CalibrationResidual],
        xModel: RidgeRegression.Model,
        yModel: RidgeRegression.Model,
        basis: PolynomialBasis,
        context: CalibrationContext? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.isCalibrated = isCalibrated
        self.validationErrorNormalized = validationErrorNormalized
        self.validationErrorPixels = validationErrorPixels
        self.pointCount = pointCount
        self.residuals = residuals
        self.xModel = xModel
        self.yModel = yModel
        self.basis = basis
        self.context = context
    }

    /// Predicts a screen position, in normalised screen coordinates with origin
    /// top-left, from a raw feature vector.
    ///
    /// Returns `nil` when the sample is unusable (a blink, or a lost face) so callers
    /// are forced to handle it rather than propagating a garbage point. The old
    /// pipeline had no such path — a blink became a cursor jump.
    public func predict(features: GazeFeatures) -> GazePoint? {
        guard isCalibrated, schemaVersion == GazeFeatures.schemaVersion, features.isUsable else {
            return nil
        }
        let row = basis.designRow(for: features.vector)
        let x = xModel.predict(designRow: row)
        let y = yModel.predict(designRow: row)

        // Clamp rather than reject. A prediction slightly outside the screen is a
        // normal edge case at the very corners, and snapping it to the border is
        // strictly better than dropping the frame.
        return GazePoint(
            x: min(max(x, 0.0), 1.0),
            y: min(max(y, 0.0), 1.0),
            confidence: features.confidence,
            timestamp: features.timestamp
        )
    }
}
