import Foundation
import Vision
import LyraCore

/// Converts a Vision face observation into the raw feature vector that calibration
/// consumes.
///
/// The important property here is that this type does *not* estimate where the user is
/// looking. It measures the eye and head, and stops. The previous implementation folded
/// a hand-tuned "sensitivity" constant into each measurement and emitted a screen point,
/// which meant calibration could only ever fit a correction curve on top of a guess.
/// Measuring and estimating are separated so the regression can learn the real mapping.
///
/// Two things are done carefully, because they dominate accuracy:
///
/// **Roll invariance.** Eye-corner positions rotate with head tilt. Measuring pupil
/// position as an axis-aligned offset (as the old code did) makes a tilted head look
/// like a large horizontal gaze shift. Everything here is projected into an eye-local
/// frame built from the corners themselves, so head roll cancels out.
///
/// **Blink rejection.** A closing eyelid drags the pupil estimate toward the lid, which
/// the model reads as a large vertical gaze movement. Rather than filtering that out
/// downstream, the eye's openness is measured per frame and used to reject the sample.
public struct FaceFeatureExtractor: Sendable {

    /// Slow-moving per-user baseline for how tall an open eye looks, so openness is
    /// judged relative to this person's face rather than a fixed constant.
    private var opennessBaseline = AdaptiveBaseline(initial: 0.25, adaptationRate: 0.02, floor: 0.08)

    public init() {}

    /// Extracts features, or returns `nil` when the frame cannot support a measurement.
    public mutating func extract(
        from observation: VNFaceObservation,
        poseSource: VNFaceObservation? = nil
    ) -> GazeFeatures? {
        let boundingBox = observation.boundingBox
        guard boundingBox.width > 0.06, boundingBox.height > 0.06 else { return nil }
        guard let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye?.normalizedPoints,
              let rightEye = landmarks.rightEye?.normalizedPoints,
              leftEye.count >= 4, rightEye.count >= 4 else { return nil }

        let leftPupil = landmarks.leftPupil?.normalizedPoints.first
        let rightPupil = landmarks.rightPupil?.normalizedPoints.first

        // With neither pupil there is nothing to measure gaze from. Reporting a neutral
        // value here would be worse than reporting nothing: it would look like a valid
        // sample that always predicts the centre of the screen.
        guard leftPupil != nil || rightPupil != nil else { return nil }

        let left = eyeGeometry(contour: leftEye, pupil: leftPupil, boundingBox: boundingBox)
        let right = eyeGeometry(contour: rightEye, pupil: rightPupil, boundingBox: boundingBox)

        // Fuse the two eyes. Both are looking at the same place, so averaging cancels a
        // good deal of the per-eye estimation noise.
        var pupilXValues: [Double] = []
        var pupilYValues: [Double] = []
        var opennessValues: [Double] = []
        if let left { pupilXValues.append(left.normalizedX); pupilYValues.append(left.normalizedY); opennessValues.append(left.openness) }
        if let right { pupilXValues.append(right.normalizedX); pupilYValues.append(right.normalizedY); opennessValues.append(right.openness) }

        guard !pupilXValues.isEmpty else { return nil }

        let rawOpenness = opennessValues.reduce(0, +) / Double(opennessValues.count)
        let openness = opennessBaseline.normalized(rawOpenness)

        // Inter-pupil distance in image space is the depth cue: it shrinks as the user
        // leans back and grows as they lean in.
        let leftCentre = centroid(of: leftEye)
        let rightCentre = centroid(of: rightEye)
        let imageLeft = toImageSpace(leftCentre, boundingBox: boundingBox)
        let imageRight = toImageSpace(rightCentre, boundingBox: boundingBox)
        let iod = Double(hypot(imageRight.x - imageLeft.x, imageRight.y - imageLeft.y))

        // High-precision rigid skull-anchored head pose:
        // By building an orthonormal basis from the outer corners of the eyes directly in
        // face space, bounding box translation and scale breathing cancel out completely.
        // In Vision 2D landmarks:
        // - leftEye points belong to face's left eye (camera's right side, larger x).
        // - rightEye points belong to face's right eye (camera's left side, smaller x).
        let cL = leftEye.max(by: { $0.x < $1.x }) ?? leftCentre
        let cR = rightEye.min(by: { $0.x < $1.x }) ?? rightCentre

        let skullMidX = Double(cL.x + cR.x) / 2.0
        let skullMidY = Double(cL.y + cR.y) / 2.0

        let skullDx = Double(cL.x - cR.x)
        let skullDy = Double(cL.y - cR.y)
        let skullBaseline = hypot(skullDx, skullDy)
        let safeBaseline = max(skullBaseline, 1e-4)

        // Orthonormal frame (u: along eye line from right to left; v: upward perpendicular)
        let ux = skullDx / safeBaseline
        let uy = skullDy / safeBaseline
        let vx = -uy
        let vy = ux

        let noseTip = landmarks.noseCrest?.normalizedPoints.last
            ?? landmarks.nose?.normalizedPoints.first

        let landmarkYaw: Double
        let landmarkPitch: Double
        if let noseTip {
            let toNoseX = Double(noseTip.x) - skullMidX
            let toNoseY = Double(noseTip.y) - skullMidY

            let projX = (toNoseX * ux + toNoseY * uy) / safeBaseline
            let projY = (toNoseX * vx + toNoseY * vy) / safeBaseline

            // Yaw: turning right moves nose to camera left -> projX decreases -> -projX increases (positive)
            landmarkYaw = -projX
            // Pitch: tilting up moves nose higher in image -> projY increases (positive), nodding down -> projY decreases (negative)
            landmarkPitch = projY
        } else {
            landmarkYaw = poseSource?.yaw?.doubleValue ?? observation.yaw?.doubleValue ?? 0.0
            landmarkPitch = poseSource?.pitch?.doubleValue ?? observation.pitch?.doubleValue ?? 0.0
        }
        let landmarkRoll = Double(atan2(imageRight.y - imageLeft.y, imageRight.x - imageLeft.x))

        let yaw = noseTip != nil ? landmarkYaw : (poseSource?.yaw?.doubleValue ?? observation.yaw?.doubleValue ?? 0.0)
        let pitch = noseTip != nil ? landmarkPitch : (poseSource?.pitch?.doubleValue ?? observation.pitch?.doubleValue ?? 0.0)
        let roll = landmarkRoll

        // A single detected pupil is real signal, just noisier than two.
        let pupilConfidence = pupilXValues.count == 2 ? 1.0 : 0.7
        let detectionConfidence = Double(observation.confidence)

        return GazeFeatures(
            pupilX: pupilXValues.reduce(0, +) / Double(pupilXValues.count),
            pupilY: pupilYValues.reduce(0, +) / Double(pupilYValues.count),
            yaw: yaw,
            pitch: pitch,
            roll: roll,
            faceX: Double(boundingBox.midX),
            faceY: Double(boundingBox.midY),
            iod: iod,
            faceWidth: Double(boundingBox.width),
            eyeOpenness: openness,
            confidence: detectionConfidence * pupilConfidence,
            timestamp: Date()
        )
    }

    /// Resets per-user baselines. Called when tracking restarts so a stale baseline from
    /// a previous session or a different person does not leak in.
    public mutating func reset() {
        opennessBaseline = AdaptiveBaseline(initial: 0.25, adaptationRate: 0.02, floor: 0.08)
    }

    // MARK: - Eye geometry

    /// Internal, not private, because `eyeGeometry` returns it and that has to be
    /// reachable from tests.
    struct EyeMeasurement {
        /// Pupil position along the corner-to-corner axis, 0 (one corner) to 1 (the other).
        let normalizedX: Double
        /// Pupil position perpendicular to that axis, 0 (lower lid) to 1 (upper lid).
        let normalizedY: Double
        /// Raw height-to-width ratio of the eye opening.
        let openness: Double
    }

    /// Projects a pupil into an eye-local coordinate frame.
    ///
    /// The frame's axes come from the eye contour's own corners, so the whole measurement
    /// rotates with the head and cancels roll.
    ///
    /// Internal rather than private so the geometry can be tested without a camera. It is
    /// the part of the pipeline most likely to break silently: see the note on the
    /// perpendicular divisor below.
    func eyeGeometry(
        contour: [CGPoint],
        pupil: CGPoint?,
        boundingBox: CGRect
    ) -> EyeMeasurement? {
        guard let pupil else { return nil }
        guard let (cornerA, cornerB) = Self.extremalCorners(of: contour) else { return nil }

        let axisX = Double(cornerB.x - cornerA.x)
        let axisY = Double(cornerB.y - cornerA.y)
        let axisLengthSquared = axisX * axisX + axisY * axisY
        guard axisLengthSquared > 1e-8 else { return nil }

        let toPupilX = Double(pupil.x - cornerA.x)
        let toPupilY = Double(pupil.y - cornerA.y)

        // Projection onto the corner axis, as a fraction of that axis.
        let along = (toPupilX * axisX + toPupilY * axisY) / axisLengthSquared

        // The perpendicular component. Dividing by the *square* of the axis length is
        // correct here: `perpendicularExtent` also divides its offsets by the axis length
        // and then projects onto an already-unit axis, so its extents come out in units
        // of `perpDistance / axisLength` too.
        let axisLength = axisLengthSquared.squareRoot()
        let perpendicular = (toPupilX * -axisY + toPupilY * axisX) / axisLengthSquared

        let extents = Self.perpendicularExtent(of: contour, cornerA: cornerA, cornerB: cornerB, axisLength: axisLength)
        let verticalSpan = max(extents.max - extents.min, 1e-4)
        let normalizedY = (perpendicular - extents.min) / verticalSpan

        return EyeMeasurement(
            normalizedX: min(max(along, 0.0), 1.0),
            normalizedY: min(max(normalizedY, 0.0), 1.0),
            openness: verticalSpan
        )
    }

    /// Finds the two contour points furthest apart — the eye corners.
    ///
    /// The returned pair is canonicalized so `cornerA` is always the corner with smaller X
    /// (the left corner in face space) and `cornerB` has larger X (the right corner in face space).
    /// This guarantees that the corner axis points in the same direction for both eyes and
    /// frame-to-frame, preventing the left and right eyes from having opposite sign and canceling
    /// each other's gaze movement out when averaged.
    static func extremalCorners(of contour: [CGPoint]) -> (CGPoint, CGPoint)? {
        guard contour.count >= 3 else { return nil }
        var best: (CGPoint, CGPoint)?
        var bestDistance: Double = 0

        for i in 0..<contour.count {
            for j in (i + 1)..<contour.count {
                let dx = Double(contour[j].x - contour[i].x)
                let dy = Double(contour[j].y - contour[i].y)
                let distance = dx * dx + dy * dy
                if distance > bestDistance {
                    bestDistance = distance
                    best = (contour[i], contour[j])
                }
            }
        }
        guard var (cornerA, cornerB) = best else { return nil }
        if cornerA.x > cornerB.x || (cornerA.x == cornerB.x && cornerA.y > cornerB.y) {
            swap(&cornerA, &cornerB)
        }
        return (cornerA, cornerB)
    }

    /// Min and max of the contour projected onto the axis perpendicular to the corner line.
    static func perpendicularExtent(
        of contour: [CGPoint],
        cornerA: CGPoint,
        cornerB: CGPoint,
        axisLength: Double
    ) -> (min: Double, max: Double) {
        let axisX = Double(cornerB.x - cornerA.x) / axisLength
        let axisY = Double(cornerB.y - cornerA.y) / axisLength
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude

        for point in contour {
            let dx = Double(point.x - cornerA.x) / axisLength
            let dy = Double(point.y - cornerA.y) / axisLength
            let perpendicular = -dy * axisX + dx * axisY
            minimum = Swift.min(minimum, perpendicular)
            maximum = Swift.max(maximum, perpendicular)
        }
        return (minimum, maximum)
    }

    private func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sumX = points.reduce(0.0) { $0 + Double($1.x) }
        let sumY = points.reduce(0.0) { $0 + Double($1.y) }
        return CGPoint(x: sumX / Double(points.count), y: sumY / Double(points.count))
    }

    /// Face-relative normalised point to image-normalised point.
    private func toImageSpace(_ point: CGPoint, boundingBox: CGRect) -> CGPoint {
        CGPoint(
            x: boundingBox.minX + point.x * boundingBox.width,
            y: boundingBox.minY + point.y * boundingBox.height
        )
    }
}

/// Tracks a slowly adapting reference value, used to judge eye openness relative to a
/// particular person's face rather than a hard-coded constant.
///
/// The asymmetry matters: the baseline ratchets *up* quickly when a wider-open eye is
/// seen, but decays only very slowly. If it adapted downward at the same rate, a long
/// blink or a squint would drag the baseline down and every subsequent open eye would
/// read as wide, defeating the blink detection it exists to support.
struct AdaptiveBaseline: Sendable {
    private var value: Double
    private let adaptationRate: Double
    private let floor: Double

    init(initial: Double, adaptationRate: Double, floor: Double) {
        self.value = initial
        self.adaptationRate = adaptationRate
        self.floor = floor
    }

    /// Returns the input expressed as a fraction of the current baseline, clamped to 0...1.
    mutating func normalized(_ measurement: Double) -> Double {
        if measurement > value {
            value += (measurement - value) * adaptationRate * 4
        } else {
            value -= (value - measurement) * adaptationRate * 0.2
        }
        value = max(value, floor)
        guard value > 1e-6 else { return 0 }
        return min(max(measurement / value, 0.0), 1.0)
    }
}
