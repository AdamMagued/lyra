import Foundation

/// Ridge (Tikhonov-regularised) least squares.
///
/// Solves `min ||Xc - y||^2 + lambda * ||c||^2` for `c`, which is the closed-form
/// solution `(XᵀX + lambda·I) c = Xᵀy`.
///
/// Two details matter for gaze calibration specifically, and both were missing before:
///
/// 1. **Feature standardisation.** Raw features live on wildly different scales — head
///    yaw is ~0.1 rad while a pupil ratio is ~0.5. An unregularised penalty applied to
///    coefficients on those scales punishes the small-magnitude features far harder than
///    the large ones. We z-score every column before fitting and fold the transform into
///    the stored coefficients afterwards, so prediction needs no extra state.
///
/// 2. **Honest error.** `fit` returns the *training* residual; `crossValidatedError`
///    returns a leave-one-out estimate that never saw the point it is scoring. The old
///    code reported the first as if it were the second.
public struct RidgeRegression: Sendable {

    /// Fitted model: coefficients in standardised space, plus the transform.
    public struct Model: Sendable, Codable, Equatable {
        public let coefficients: [Double]
        public let means: [Double]
        public let scales: [Double]

        /// Evaluates the model for a single design-matrix row.
        ///
        /// `row` is a *design* row: index 0 is the bias, and indices 1... are the basis
        /// columns that `means`/`scales` describe. The offset matters — reading from
        /// index 0 instead feeds the constant bias term in as though it were the first
        /// feature, and every feature's value is then taken from its neighbour.
        public func predict(designRow row: [Double]) -> Double {
            var total = coefficients.first ?? 0.0
            for j in 0..<(coefficients.count - 1) {
                let raw = (j + 1) < row.count ? row[j + 1] : 0.0
                let scale = scales[j]
                let standardised = scale > 1e-12 ? (raw - means[j]) / scale : 0.0
                total += coefficients[j + 1] * standardised
            }
            return total
        }
    }

    /// Regularisation strength. Larger = smoother, more shrinkage, less overfitting.
    public var lambda: Double

    public init(lambda: Double = 1.0) {
        self.lambda = lambda
    }

    /// Fits a model to a design matrix and target vector.
    ///
    /// - Parameters:
    ///   - design: `n` rows, each the expanded basis for one calibration sample.
    ///     Row length must equal `featureDimension + 1` (leading bias column included).
    ///   - targets: `n` target values (a screen coordinate, normalised 0...1).
    public func fit(design: [[Double]], targets: [Double]) -> Model? {
        guard let dimension = design.first.map({ $0.count - 1 }), dimension > 0 else { return nil }
        guard design.count >= 2, design.count == targets.count else { return nil }
        guard design.allSatisfy({ $0.count == dimension + 1 }) else { return nil }

        let (means, scales) = Self.columnStatistics(design: design, dimension: dimension)
        let standardised = Self.standardise(design: design, means: means, scales: scales)

        guard let coefficients = solveNormalEquations(design: standardised, targets: targets) else {
            return nil
        }
        return Model(coefficients: coefficients, means: means, scales: scales)
    }

    /// Leave-one-out cross-validation error, in the same units as `targets`.
    ///
    /// Refits the model `n` times, each time holding out a single sample, and scores it
    /// on that held-out point. Standardisation is recomputed per fold so the estimate
    /// is not quietly optimistic. With the sample counts Lyra uses (tens of points,
    /// tens of terms) this costs well under a millisecond.
    public func crossValidatedError(design: [[Double]], targets: [Double]) -> Double? {
        guard design.count >= 3, design.count == targets.count else { return nil }

        var squaredError = 0.0
        for heldOut in design.indices {
            var trainDesign: [[Double]] = []
            var trainTargets: [Double] = []
            trainDesign.reserveCapacity(design.count - 1)
            trainTargets.reserveCapacity(design.count - 1)

            for i in design.indices where i != heldOut {
                trainDesign.append(design[i])
                trainTargets.append(targets[i])
            }

            guard let model = fit(design: trainDesign, targets: trainTargets) else { return nil }
            let predicted = model.predict(designRow: design[heldOut])
            let residual = predicted - targets[heldOut]
            squaredError += residual * residual
        }

        return (squaredError / Double(design.count)).squareRoot()
    }

    // MARK: - Normal equations

    private func solveNormalEquations(design: [[Double]], targets: [Double]) -> [Double]? {
        guard let rowWidth = design.first?.count else { return nil }
        let n = rowWidth

        // M = XᵀX + lambda·I, but never penalising the bias term, which must stay free
        // to absorb the mean offset of the target.
        var matrix = [[Double]](repeating: [Double](repeating: 0.0, count: n), count: n)
        var rhs = [Double](repeating: 0.0, count: n)

        for row in design {
            for i in 0..<n {
                let rowI = row[i]
                if rowI == 0.0 { continue }
                for j in i..<n {
                    matrix[i][j] += rowI * row[j]
                }
            }
        }
        for i in 0..<n {
            for j in 0..<i {
                matrix[i][j] = matrix[j][i]
            }
        }
        for (index, value) in targets.enumerated() {
            let row = design[index]
            for i in 0..<n {
                rhs[i] += row[i] * value
            }
        }
        for i in 1..<n {
            matrix[i][i] += lambda
        }

        return Self.solveSymmetricPositiveDefinite(matrix: matrix, rhs: rhs)
    }

    /// Cholesky decomposition with a Gauss-Jordan fallback.
    ///
    /// The normal matrix is symmetric positive definite by construction once `lambda > 0`
    /// and the design has full column rank, so Cholesky is the right tool. The fallback
    /// covers near-singular cases produced by degenerate calibrations (for example, a user
    /// who never moved their head at all), where we would rather return *something*
    /// usable than throw the whole calibration away.
    static func solveSymmetricPositiveDefinite(matrix: [[Double]], rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard matrix.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }

        var lower = [[Double]](repeating: [Double](repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var sum = matrix[i][j]
                for k in 0..<j {
                    sum -= lower[i][k] * lower[j][k]
                }
                if i == j {
                    guard sum > 1e-12 else { return solveWithPartialPivoting(matrix: matrix, rhs: rhs) }
                    lower[i][j] = sum.squareRoot()
                } else {
                    lower[i][j] = sum / lower[j][j]
                }
            }
        }

        // Forward substitution: L y = b
        var y = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            var sum = rhs[i]
            for k in 0..<i {
                sum -= lower[i][k] * y[k]
            }
            y[i] = sum / lower[i][i]
        }

        // Back substitution: Lᵀ c = y
        var c = [Double](repeating: 0.0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<n {
                sum -= lower[k][i] * c[k]
            }
            c[i] = sum / lower[i][i]
        }
        return c
    }

    static func solveWithPartialPivoting(matrix: [[Double]], rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var x = rhs

        for i in 0..<n {
            var pivotRow = i
            var pivotValue = abs(a[i][i])
            for r in (i + 1)..<n where abs(a[r][i]) > pivotValue {
                pivotValue = abs(a[r][i])
                pivotRow = r
            }
            guard pivotValue > 1e-14 else { return nil }
            if pivotRow != i {
                a.swapAt(i, pivotRow)
                x.swapAt(i, pivotRow)
            }

            let pivot = a[i][i]
            for j in i..<n { a[i][j] /= pivot }
            x[i] /= pivot

            for r in 0..<n where r != i {
                let factor = a[r][i]
                guard factor != 0.0 else { continue }
                for j in i..<n { a[r][j] -= factor * a[i][j] }
                x[r] -= factor * x[i]
            }
        }
        return x
    }

    // MARK: - Standardisation

    static func columnStatistics(design: [[Double]], dimension: Int) -> (means: [Double], scales: [Double]) {
        var means = [Double](repeating: 0.0, count: dimension)
        // Seeded at zero, not one: this array is the running sum of squared deviations,
        // and starting it at 1.0 adds 1/n to every variance. On any column whose real
        // variance is comparable to 1/n — which is most of them once features are
        // normalised — that inflates the scale enough to change what the ridge penalty
        // actually does.
        var scales = [Double](repeating: 0.0, count: dimension)
        let n = Double(design.count)

        for row in design {
            for j in 0..<dimension { means[j] += row[j + 1] }
        }
        for j in 0..<dimension { means[j] /= n }

        for row in design {
            for j in 0..<dimension {
                let delta = row[j + 1] - means[j]
                scales[j] += delta * delta
            }
        }
        for j in 0..<dimension {
            let variance = scales[j] / n
            // A column that never varies carries no information; scaling it to 1
            // collapses it to zero after centring, which the fit then ignores.
            scales[j] = variance > 1e-12 ? variance.squareRoot() : 1.0
        }

        return (means, scales)
    }

    static func standardise(design: [[Double]], means: [Double], scales: [Double]) -> [[Double]] {
        let dimension = means.count
        return design.map { row in
            var output = [Double](repeating: 0.0, count: dimension + 1)
            output[0] = row[0]
            for j in 0..<dimension {
                let scale = scales[j]
                output[j + 1] = scale > 1e-12 ? (row[j + 1] - means[j]) / scale : 0.0
            }
            return output
        }
    }
}
