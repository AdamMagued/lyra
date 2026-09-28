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

    /// Reference head posture and distance captured during calibration.
    ///
    /// Used during live tracking to geometrically decouple head movements (yaw, pitch, roll, distance, translation)
    /// from pupil gaze coordinates.
    public struct HeadBaseline: Codable, Sendable, Equatable {
        public let faceX: Double
        public let faceY: Double
        public let iod: Double
        public let faceWidth: Double
        public let yaw: Double
        public let pitch: Double
        public let roll: Double
        public let yawSpread: Double
        public let pitchSpread: Double
        public let translationSpread: Double

        public init(
            faceX: Double,
            faceY: Double,
            iod: Double,
            faceWidth: Double,
            yaw: Double,
            pitch: Double,
            roll: Double,
            yawSpread: Double = 0.0,
            pitchSpread: Double = 0.0,
            translationSpread: Double = 0.0
        ) {
            self.faceX = faceX
            self.faceY = faceY
            self.iod = iod
            self.faceWidth = faceWidth
            self.yaw = yaw
            self.pitch = pitch
            self.roll = roll
            self.yawSpread = yawSpread
            self.pitchSpread = pitchSpread
            self.translationSpread = translationSpread
        }

        /// Computes the average head posture across a set of calibration feature vectors.
        public static func compute(from featureVectors: [[Double]]) -> HeadBaseline? {
            guard !featureVectors.isEmpty else { return nil }
            let count = Double(featureVectors.count)
            var sums = [Double](repeating: 0.0, count: GazeFeatures.featureCount)
            for vec in featureVectors {
                guard vec.count >= GazeFeatures.featureCount else { return nil }
                for i in 0..<GazeFeatures.featureCount {
                    sums[i] += vec[i]
                }
            }
            let meanFaceX = sums[5] / count
            let meanFaceY = sums[6] / count
            let meanYaw = sums[2] / count
            let meanPitch = sums[3] / count

            var yawVar = 0.0
            var pitchVar = 0.0
            var transVar = 0.0
            for vec in featureVectors {
                yawVar += pow(vec[2] - meanYaw, 2)
                pitchVar += pow(vec[3] - meanPitch, 2)
                let dx = vec[5] - meanFaceX
                let dy = vec[6] - meanFaceY
                transVar += dx * dx + dy * dy
            }

            return HeadBaseline(
                faceX: meanFaceX,
                faceY: meanFaceY,
                iod: max(sums[7] / count, 0.01),
                faceWidth: max(sums[8] / count, 0.01),
                yaw: meanYaw,
                pitch: meanPitch,
                roll: sums[4] / count,
                yawSpread: (yawVar / count).squareRoot(),
                pitchSpread: (pitchVar / count).squareRoot(),
                translationSpread: (transVar / count).squareRoot()
            )
        }

        /// Compensates a raw feature vector relative to this baseline posture.
        ///
        /// 1. Head yaw counter-rotation (VOR): when the head yaws, the eyes counter-rotate
        ///    in their sockets to maintain screen fixation. We subtract this counter-rotation.
        /// 2. Head pitch counter-rotation: vertical head nod compensation.
        /// 3. Head roll rotation: rotates pupil displacements back to screen-aligned coordinates.
        /// 4. Distance scaling: perspective pupil travel scales inversely with distance (IOD).
        public func compensate(vector: [Double]) -> [Double] {
            guard vector.count >= GazeFeatures.featureCount else { return vector }
            let pupilX = vector[0]
            let pupilY = vector[1]
            let yaw = vector[2]
            let pitch = vector[3]
            let roll = vector[4]
            let iod = vector[7]
            let faceWidth = vector[8]

            let deltaYaw = yaw - self.yaw
            let deltaPitch = pitch - self.pitch
            let deltaRoll = roll - self.roll
            let distanceScale = max(0.6, min(1.8, iod / max(self.iod, 1e-4)))

            // If calibration data already had active head rotation variance (>= 0.035 rad),
            // the regression model will have fitted its own head pose weights from that data.
            // When the user held their head still (yawSpread < 0.020 rad, typical for calm gaze tracking),
            // the regression has near-zero weights for pose, so full geometric compensation applies.
            let yawGain = max(0.0, min(1.0, 1.0 - (yawSpread - 0.020) / 0.015))
            let pitchGain = max(0.0, min(1.0, 1.0 - (pitchSpread - 0.020) / 0.015))

            // VOR counter-rotation compensation
            let px = (pupilX - 0.5) + (0.38 * yawGain) * deltaYaw
            let py = (pupilY - 0.5) + (0.32 * pitchGain) * deltaPitch

            // Roll rotation: align eye frame with screen frame
            let cosR = cos(-deltaRoll * yawGain)
            let sinR = sin(-deltaRoll * yawGain)
            let rotX = px * cosR - py * sinR
            let rotY = px * sinR + py * cosR

            // Distance scaling (perspective eye movement)
            let effectiveDistScale = 1.0 + (distanceScale - 1.0) * yawGain
            let compX = min(max(0.5 + rotX / effectiveDistScale, 0.05), 0.95)
            let compY = min(max(0.5 + rotY / effectiveDistScale, 0.05), 0.95)

            let effectiveYaw = self.yaw + deltaYaw * (1.0 - yawGain)
            let effectivePitch = self.pitch + deltaPitch * (1.0 - pitchGain)
            let effectiveRoll = self.roll + deltaRoll * (1.0 - yawGain)
            let effectiveIod = self.iod + (iod - self.iod) * (1.0 - yawGain)
            let effectiveFaceWidth = self.faceWidth + (faceWidth - self.faceWidth) * (1.0 - yawGain)

            return [
                compX,
                compY,
                effectiveYaw,
                effectivePitch,
                effectiveRoll,
                self.faceX,
                self.faceY,
                effectiveIod,
                effectiveFaceWidth
            ]
        }
    }

    /// Neutral head posture recorded during calibration. Used to compensate live features.
    public let headBaseline: HeadBaseline?

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
        headBaseline: nil,
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
        headBaseline: HeadBaseline? = nil,
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
        self.headBaseline = headBaseline
        self.context = context
    }

    /// Predicts a screen position, in normalised screen coordinates with origin
    /// top-left, from a raw feature vector.
    ///
    /// When a `headBaseline` is present, geometrically compensates pupil coordinates
    /// for head yaw, pitch, roll, distance scaling, and translation parallax before evaluation.
    ///
    /// Returns `nil` when the sample is unusable (a blink, or a lost face) so callers
    /// are forced to handle it rather than propagating a garbage point.
    public func predict(features: GazeFeatures) -> GazePoint? {
        guard isCalibrated, schemaVersion == GazeFeatures.schemaVersion, features.isUsable else {
            return nil
        }

        let effectiveVector: [Double]
        let parallaxX: Double
        let parallaxY: Double

        if let baseline = headBaseline {
            effectiveVector = baseline.compensate(vector: features.vector)
            // Parallax offset: lateral and vertical head translation.
            // Full geometric parallax compensation applies unless calibration itself had massive translation.
            let translationGain = max(0.0, min(1.0, 1.0 - (baseline.translationSpread - 0.010) / 0.010))
            let kParallax = 1.1 * translationGain
            let rawParallaxX = -kParallax * (features.faceX - baseline.faceX)
            let rawParallaxY = -kParallax * (features.faceY - baseline.faceY)
            // Soft-clamp parallax so moving the laptop or a large head posture shift cannot hijack the cursor
            parallaxX = min(max(rawParallaxX, -0.045), 0.045)
            parallaxY = min(max(rawParallaxY, -0.045), 0.045)
        } else {
            effectiveVector = features.vector
            parallaxX = 0.0
            parallaxY = 0.0
        }

        let row = basis.designRow(for: effectiveVector)
        let x = xModel.predict(designRow: row) + parallaxX
        let y = yModel.predict(designRow: row) + parallaxY

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
