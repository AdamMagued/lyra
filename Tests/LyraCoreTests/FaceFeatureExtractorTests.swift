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

        XCTAssertEqual(top ?? -1, 0.0, accuracy: 0.05)
        XCTAssertEqual(bottom ?? -1, 1.0, accuracy: 0.05)
    }

    func testVerticalResponseIsLinearAndSymmetricAboutTheCentre() {
        // Equal steps up and down have to move the measurement by equal amounts, or the
        // fit has to spend curvature terms modelling an artefact of the geometry.
        let quarter = measure(pupil: CGPoint(x: 0.5, y: 0.5 + halfHeight / 2))?.normalizedY
        let threeQuarters = measure(pupil: CGPoint(x: 0.5, y: 0.5 - halfHeight / 2))?.normalizedY

        XCTAssertEqual(quarter ?? -1, 0.25, accuracy: 0.05)
        XCTAssertEqual(threeQuarters ?? -1, 0.75, accuracy: 0.05)
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
