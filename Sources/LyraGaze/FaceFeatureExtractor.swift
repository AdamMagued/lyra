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
    private var opennessBaseline = AdaptiveBaseline(initial: 0.32, adaptationRate: 0.02, floor: 0.10)

    public init() {}

    /// Extracts features, or returns `nil` when the frame cannot support a measurement.
    public mutating func extract(from observation: VNFaceObservation) -> GazeFeatures? {
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

        // A single detected pupil is real signal, just noisier than two.
        let pupilConfidence = pupilXValues.count == 2 ? 1.0 : 0.7
        let detectionConfidence = Double(observation.confidence)

        return GazeFeatures(
            pupilX: pupilXValues.reduce(0, +) / Double(pupilXValues.count),
            pupilY: pupilYValues.reduce(0, +) / Double(pupilYValues.count),
            yaw: Double(observation.yaw?.doubleValue ?? 0),
            pitch: Double(observation.pitch?.doubleValue ?? 0),
            roll: Double(observation.roll?.doubleValue ?? 0),
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
        opennessBaseline = AdaptiveBaseline(initial: 0.32, adaptationRate: 0.02, floor: 0.10)
    }

    // MARK: - Eye geometry

    private struct EyeMeasurement {
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
    private func eyeGeometry(
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

        // Projection onto the corner axis gives horizontal eye-in-head position.
        let along = (toPupilX * axisX + toPupilY * axisY) / axisLengthSquared

        // The perpendicular component is the vertical signal. Because the contour is
        // stored in face-relative space it must be normalised by the eye's own height,
        // measured in that same space.
        let axisLength = axisLengthSquared.squareRoot()
        let perpendicular = (toPupilX * -axisY + toPupilY * axisX) / axisLengthSquared

        let extents = Self.perpendicularExtent(of: contour, cornerA: cornerA, cornerB: cornerB, axisLength: axisLength)
        let verticalSpan = max(extents.max - extents.min, 1e-4)
        let normalizedY = (perpendicular - extents.min) / verticalSpan

        return EyeMeasurement(
            normalizedX: min(max(along, 0.0), 1.0),
            normalizedY: min(max(normalizedY, 0.0), 1.0),
            openness: verticalSpan / max(axisLength, 1e-4)
        )
    }

    /// Finds the two contour points furthest apart — the eye corners.
    ///
    /// Using an exhaustive search rather than, say, the leftmost and rightmost points is
    /// deliberate: with a tilted or partially occluded eye the extreme-x points can both
    /// land on the same corner, which would collapse the local frame.
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
        return best
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
