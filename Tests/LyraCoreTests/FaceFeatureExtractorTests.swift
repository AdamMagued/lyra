import XCTest
import CoreGraphics
@testable import LyraGaze

/// The eye-local geometry, which is where gaze accuracy is actually won or lost.
///
/// Written while chasing a reported ~300 px calibration error. The first version of this
/// file asserted a bug that did not exist — the perpendicular divisor is correct, and
/// easy to mistake for a bug, because `perpendicularExtent` normalises by the axis length
/// twice (once in the offsets, once in the unit axis it projects onto). Both sides of the
/// subtraction in `eyeGeometry` are in `perpDistance / axisLength` units, so the ratio is
/// the clean 0...1 fraction it looks like.
///
/// What the file is for now is the property that matters and is silent when it breaks:
/// the pupil's full travel, lower lid to upper lid, has to span the whole 0...1 range.
/// Any scaling mistake here compresses vertical gaze into a sliver of the range, the fit
/// finds nothing to learn, and calibration reports the accuracy of a model that predicts
/// the middle of the screen.
final class FaceFeatureExtractorTests: XCTestCase {

    private let halfWidth = 0.12
    private let halfHeight = 0.03

    /// An almond eye in face-relative normalised space. The proportions are Vision's: a
    /// face-relative eye is roughly four times as wide as it is tall.
    private func contour(
        centre: CGPoint = CGPoint(x: 0.5, y: 0.5),
        halfWidth: Double? = nil,
        halfHeight: Double? = nil,
        samples: Int = 240
    ) -> [CGPoint] {
        let w = halfWidth ?? self.halfWidth
        let h = halfHeight ?? self.halfHeight
        return (0..<samples).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(samples)
            return CGPoint(
                x: Double(centre.x) + w * cos(angle),
                y: Double(centre.y) + h * sin(angle)
            )
        }
    }

    private func measure(
        pupil: CGPoint,
        contour points: [CGPoint]? = nil
    ) -> FaceFeatureExtractor.EyeMeasurement? {
        FaceFeatureExtractor().eyeGeometry(
            contour: points ?? contour(),
            pupil: pupil,
            boundingBox: .zero
        )
    }

    /// The eye's own corners, so expectations do not depend on which of the two
    /// `extremalCorners` happens to return first.
    private func corners() -> (CGPoint, CGPoint) {
        FaceFeatureExtractor.extremalCorners(of: contour())!
    }

    // MARK: - Vertical

    func testPupilAtTheVerticalCentreReadsAsHalf() {
        XCTAssertEqual(measure(pupil: CGPoint(x: 0.5, y: 0.5))?.normalizedY ?? -1, 0.5, accuracy: 0.02)
    }

    func testFullVerticalTravelSpansTheWholeRange() {
        // The regression guard. The lid-to-lid travel has to cover 0...1: if it is scaled
        // down, every point of the pattern reports a vertical value inside a narrow band
        // and the vertical fit degenerates to a constant.
        let top = measure(pupil: CGPoint(x: 0.5, y: 0.5 + halfHeight))?.normalizedY
        let bottom = measure(pupil: CGPoint(x: 0.5, y: 0.5 - halfHeight))?.normalizedY

        XCTAssertEqual(top ?? -1, 1.0, accuracy: 0.05)
        XCTAssertEqual(bottom ?? -1, 0.0, accuracy: 0.05)
    }

    func testVerticalResponseIsLinearAndSymmetricAboutTheCentre() {
        // Equal steps up and down have to move the measurement by equal amounts, or the
        // fit has to spend curvature terms modelling an artefact of the geometry.
        let quarter = measure(pupil: CGPoint(x: 0.5, y: 0.5 + halfHeight / 2))?.normalizedY
        let threeQuarters = measure(pupil: CGPoint(x: 0.5, y: 0.5 - halfHeight / 2))?.normalizedY

        XCTAssertEqual(quarter ?? -1, 0.75, accuracy: 0.05)
        XCTAssertEqual(threeQuarters ?? -1, 0.25, accuracy: 0.05)
    }

    // MARK: - Horizontal

    func testHorizontalPositionIsAFractionAlongTheCornerAxis() {
        let (a, b) = corners()
        let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        XCTAssertEqual(measure(pupil: midpoint)?.normalizedX ?? -1, 0.5, accuracy: 0.02)

        // A quarter of the way from the first corner to the second.
        let quarter = CGPoint(
            x: Double(a.x) + (Double(b.x) - Double(a.x)) * 0.25,
            y: Double(a.y) + (Double(b.y) - Double(a.y)) * 0.25
        )
        XCTAssertEqual(measure(pupil: quarter)?.normalizedX ?? -1, 0.25, accuracy: 0.03)
    }

    // MARK: - Two-eye consistency

    func testBothEyesAgreeOnGazeDirection() {
        // In Vision, leftEye and rightEye landmark points are returned in opposite winding order.
        // Canonicalizing the corners ensures that moving the eyes in a given direction shifts
        // both eye measurements in the same direction, preventing them from canceling each other out.
        let extractor = FaceFeatureExtractor()

        let leftContour = [
            CGPoint(x: 0.20, y: 0.68),
            CGPoint(x: 0.25, y: 0.70),
            CGPoint(x: 0.31, y: 0.71),
            CGPoint(x: 0.36, y: 0.70),
            CGPoint(x: 0.31, y: 0.68),
            CGPoint(x: 0.25, y: 0.67)
        ]
        let leftPupil = CGPoint(x: 0.28, y: 0.69)

        let rightContour = [
            CGPoint(x: 0.72, y: 0.75),
            CGPoint(x: 0.67, y: 0.76),
            CGPoint(x: 0.61, y: 0.75),
            CGPoint(x: 0.56, y: 0.73),
            CGPoint(x: 0.61, y: 0.72),
            CGPoint(x: 0.68, y: 0.73)
        ]
        let rightPupil = CGPoint(x: 0.64, y: 0.74)

        guard let leftBase = extractor.eyeGeometry(contour: leftContour, pupil: leftPupil, boundingBox: .zero),
              let rightBase = extractor.eyeGeometry(contour: rightContour, pupil: rightPupil, boundingBox: .zero) else {
            return XCTFail("Failed to measure base eye geometries")
        }

        // Shift gaze to the right (+0.02)
        guard let leftRightShift = extractor.eyeGeometry(contour: leftContour, pupil: CGPoint(x: leftPupil.x + 0.02, y: leftPupil.y), boundingBox: .zero),
              let rightRightShift = extractor.eyeGeometry(contour: rightContour, pupil: CGPoint(x: rightPupil.x + 0.02, y: rightPupil.y), boundingBox: .zero) else {
            return XCTFail("Failed to measure right-shifted eye geometries")
        }

        let leftDX = leftRightShift.normalizedX - leftBase.normalizedX
        let rightDX = rightRightShift.normalizedX - rightBase.normalizedX
        XCTAssertGreaterThan(leftDX, 0.05, "Left eye must move right")
        XCTAssertGreaterThan(rightDX, 0.05, "Right eye must move right")
        XCTAssertEqual(leftDX, rightDX, accuracy: 0.05, "Both eyes must move right by similar amounts")

        // Shift gaze upward (+0.01)
        guard let leftUpShift = extractor.eyeGeometry(contour: leftContour, pupil: CGPoint(x: leftPupil.x, y: leftPupil.y + 0.01), boundingBox: .zero),
              let rightUpShift = extractor.eyeGeometry(contour: rightContour, pupil: CGPoint(x: rightPupil.x, y: rightPupil.y + 0.01), boundingBox: .zero) else {
            return XCTFail("Failed to measure up-shifted eye geometries")
        }

        let leftDY = leftUpShift.normalizedY - leftBase.normalizedY
        let rightDY = rightUpShift.normalizedY - rightBase.normalizedY
        XCTAssertGreaterThan(leftDY, 0.1, "Left eye must move up")
        XCTAssertGreaterThan(rightDY, 0.1, "Right eye must move up")
        XCTAssertEqual(leftDY, rightDY, accuracy: 0.1, "Both eyes must move up by similar amounts")
    }

    // MARK: - Roll invariance

    func testRollingTheEyeDoesNotChangeTheMeasurement() {
        // The reason the eye-local frame exists: a tilted head must not read as a gaze
        // shift. Contour and pupil rotate together, so neither coordinate may move.
        let angle = 0.35
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = Double(point.x) - 0.5
            let dy = Double(point.y) - 0.5
            return CGPoint(
                x: 0.5 + dx * cos(angle) - dy * sin(angle),
                y: 0.5 + dx * sin(angle) + dy * cos(angle)
            )
        }

        let pupil = CGPoint(x: 0.5, y: 0.5 + halfHeight / 2)
        let upright = measure(pupil: pupil)
        let tilted = measure(pupil: rotate(pupil), contour: contour().map(rotate))

        XCTAssertEqual(upright?.normalizedY ?? -1, tilted?.normalizedY ?? -2, accuracy: 0.03)
        XCTAssertEqual(upright?.normalizedX ?? -1, tilted?.normalizedX ?? -2, accuracy: 0.03)
    }

    // MARK: - Openness

    func testOpennessGrowsWithHowFarTheEyeIsOpen() {
        // Blink rejection compares this against a per-user baseline, so what matters is
        // that it is monotone in the opening rather than its absolute value.
        let narrowed = measure(
            pupil: CGPoint(x: 0.5, y: 0.5),
            contour: contour(halfHeight: halfHeight / 2)
        )?.openness
        let open = measure(pupil: CGPoint(x: 0.5, y: 0.5))?.openness

        XCTAssertNotNil(narrowed)
        XCTAssertNotNil(open)
        XCTAssertLessThan(narrowed ?? 1, open ?? 0)
    }
}
