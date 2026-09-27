import Foundation

/// Expands raw feature vectors into the polynomial basis used by gaze calibration.
///
/// Gaze-to-screen is not linear: the mapping bends noticeably at the screen edges
/// (perspective, and the eye's own non-linear rotation-to-position relationship). A
/// second-order expansion captures that curvature.
///
/// The expansion is deliberately *asymmetric*, which is the main design decision here:
///
/// - The first `primaryFeatureCount` features — pupil position and head yaw/pitch —
///   are the signals that actually correlate with gaze direction, so they get the full
///   second-order treatment including cross terms.
/// - The remaining features — roll, face translation, depth cues — are corrections to
///   the model rather than drivers of it. Squaring them, or crossing them with each
///   other, buys nothing and multiplies the number of free parameters the fit has to
///   constrain from a handful of calibration points.
///
/// For the default 4 primary features that is 1 + 4 + 4 + 6 = 15 terms, plus one linear
/// term for each of the 5 secondary features: 20 terms total.
///
/// Which sets a hard floor on the calibration pattern: a fit needs *more* points than
/// terms. Measuring the real design matrix on a 20-point grid gives rank 19, because
/// pupil position, head rotation and head translation are correlated even when the
/// fixture is built to separate them. Twenty points against twenty terms is a square
/// system, and a square system's last direction is decided by the ridge penalty rather
/// than by anything the user did. Hence 25 points in the standard pattern.
public struct PolynomialBasis: Sendable, Equatable, Codable {

    /// How many of the leading features receive the quadratic expansion.
    public let primaryFeatureCount: Int

    /// Polynomial degree applied to the primary features. 1 = affine, 2 = quadratic.
    public let degree: Int

    public init(primaryFeatureCount: Int = 4, degree: Int = 2) {
        self.primaryFeatureCount = primaryFeatureCount
        self.degree = degree
    }

    public static let `default` = PolynomialBasis()

    /// Number of columns in the design matrix row, bias included.
    public var termCount: Int {
        var count = 1 // bias
        for d in 1...max(degree, 1) {
            count += Self.combinations(of: primaryFeatureCount, choose: d, withRepetition: true)
        }
        count += max(GazeFeatures.featureCount - primaryFeatureCount, 0)
        return count
    }

    /// Builds one design-matrix row for a feature vector.
    ///
    /// Layout: `[1, primary terms..., secondary linear terms...]`.
    public func designRow(for features: [Double]) -> [Double] {
        var row: [Double] = [1.0]
        row.reserveCapacity(termCount)

        let primaryCount = min(primaryFeatureCount, features.count)
        let primary = Array(features.prefix(primaryCount))

        // Every monomial of degree 1...degree over the primary features, in a stable order.
        for d in 1...max(degree, 1) {
            for exponents in Self.exponentTuples(count: primaryCount, degree: d) {
                var term = 1.0
                for (index, exponent) in exponents.enumerated() where exponent > 0 {
                    term *= pow(primary[index], Double(exponent))
                }
                row.append(term)
            }
        }

        // Secondary features enter linearly.
        if features.count > primaryCount {
            row.append(contentsOf: features.dropFirst(primaryCount))
        }

        return row
    }

    // MARK: - Combinatorics

    /// Number of monomials of exactly `degree` over `count` variables.
    /// Stars and bars: C(count + degree - 1, degree).
    static func combinations(of count: Int, choose degree: Int, withRepetition: Bool) -> Int {
        guard count > 0, degree > 0 else { return 1 }
        var result = 1
        for i in 0..<degree {
            result = result * (count + i) / (i + 1)
        }
        return result
    }

    /// Exponent tuples for every monomial of exactly `degree` over `count` variables,
    /// in a deterministic order so saved calibrations stay interpretable.
    static func exponentTuples(count: Int, degree: Int) -> [[Int]] {
        guard count > 0 else { return [] }
        if degree == 1 {
            return (0..<count).map { index in
                var tuple = [Int](repeating: 0, count: count)
                tuple[index] = 1
                return tuple
            }
        }

        var results: [[Int]] = []
        for firstExponent in stride(from: degree, through: 0, by: -1) {
            if count == 1 {
                if firstExponent == degree { results.append([degree]) }
                continue
            }
            for rest in exponentTuples(count: count - 1, degree: degree - firstExponent) {
                results.append([firstExponent] + rest)
            }
        }
        return results
    }
}
