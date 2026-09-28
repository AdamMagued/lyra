import Foundation

/// Turns a set of calibration observations into a `CalibrationMap`.
///
/// Deliberately pure and hardware-free so it can be unit tested with synthetic
/// features, which matters a lot here: gaze calibration is the part of Lyra that is
/// hardest to verify by hand and easiest to get subtly wrong.
///
/// The pipeline is: reject untrustworthy samples, fit, prune outliers, refit, then
/// score the result with leave-one-out cross-validation. The pruning pass exists
/// because a single bad point — a blink caught mid-capture, a head turn, a glance
/// away during the hold — is enough to bend a polynomial noticeably, and users cannot
/// tell that happened until the cursor misbehaves somewhere unrelated.
public struct GazeCalibrator: Sendable {

    public var basis: PolynomialBasis

    /// Ridge strength in standardised space. Deliberately not tiny: with ~20 terms
    /// and 13-25 points, an almost-unregularised fit chases per-point noise and
    /// generalises worse, which is exactly the failure mode we are trying to leave behind.
    public var lambda: Double

    /// Outlier pruning threshold, in multiples of the median absolute residual.
    public var outlierThresholdMAD: Double

    /// Below this many usable samples, calibration is refused rather than guessed at.
    public var minimumSamples: Int

    public init(
        basis: PolynomialBasis = .default,
        lambda: Double = 1.0,
        outlierThresholdMAD: Double = 3.0,
        minimumSamples: Int = 8
    ) {
        self.basis = basis
        self.lambda = lambda
        self.outlierThresholdMAD = outlierThresholdMAD
        self.minimumSamples = minimumSamples
    }

    public enum CalibrationError: Error, LocalizedError, Equatable {
        case insufficientSamples(have: Int, need: Int)
        case fitFailed
        case poorFit(errorPixels: Double)

        public var errorDescription: String? {
            switch self {
            case .insufficientSamples(let have, let need):
                return "Only \(have) usable calibration points were captured; \(need) are needed. Try again and hold each dot steadily."
            case .fitFailed:
                return "Calibration could not be solved. This usually means the points were all looked at from the same head position — try again and move your head naturally."
            case .poorFit(let errorPixels):
                return String(format: "Calibration did not converge well (average error %.0f px). Try again in more even lighting, keeping your head within a comfortable range.", errorPixels)
            }
        }
    }

    /// Fits a calibration map, or throws if the data cannot support one.
    ///
    /// - Parameters:
    ///   - samples: raw calibration observations.
    ///   - screenWidth: used only to report error in pixels.
    ///   - screenHeight: used only to report error in pixels.
    ///   - context: the display and camera this was measured against, recorded so the map
    ///     can tell later whether it still applies. See `CalibrationMap.CalibrationContext`.
    public func calibrate(
        samples: [CalibrationSample],
        screenWidth: Double,
        screenHeight: Double,
        context: CalibrationMap.CalibrationContext? = nil
    ) throws -> CalibrationMap {
        let usable = samples.filter { $0.isTrustworthy() }
        guard usable.count >= minimumSamples else {
            throw CalibrationError.insufficientSamples(have: usable.count, need: minimumSamples)
        }
        guard usable.allSatisfy({ $0.features.count == GazeFeatures.featureCount }) else {
            throw CalibrationError.fitFailed
        }

        let pruned = pruneOutliers(samples: usable)
        guard pruned.count >= minimumSamples else {
            throw CalibrationError.fitFailed
        }

        // Establish baseline head posture and distance from the accepted calibration points.
        let baseline = CalibrationMap.HeadBaseline.compute(from: pruned.map(\.features))

        let design = pruned.map { basis.designRow(for: $0.features) }
        let targetXs = pruned.map(\.targetX)
        let targetYs = pruned.map(\.targetY)

        // Pick the ridge strength by held-out error rather than by hand. `lambda` is a
        // starting point, not an answer: the right value depends on how much the user's
        // features actually varied, which is different for every person and every
        // lighting setup. Choosing it takes a few hundred tiny solves and is the single
        // cheapest accuracy win available here.
        let selection = selectRegularisation(
            design: design,
            targetXs: targetXs,
            targetYs: targetYs
        )

        let regression = RidgeRegression(lambda: selection.lambda)
        guard let xModel = regression.fit(design: design, targets: targetXs),
              let yModel = regression.fit(design: design, targets: targetYs) else {
            throw CalibrationError.fitFailed
        }

        // Honest generalisation estimate: each point scored by a model that never saw it.
        let errorNormalized = selection.errorNormalized

        // Residuals come from the *final* model, so the UI map reflects what is actually deployed.
        let residuals = pruned.map { sample -> CalibrationMap.CalibrationResidual in
            let row = basis.designRow(for: sample.features)
            let dx = xModel.predict(designRow: row) - sample.targetX
            let dy = yModel.predict(designRow: row) - sample.targetY
            return CalibrationMap.CalibrationResidual(
                targetX: sample.targetX,
                targetY: sample.targetY,
                error: (dx * dx + dy * dy).squareRoot()
            )
        }

        // Reported in pixels from the *held-out* error, not from the residuals above.
        // The two are different numbers, and the residuals are systematically smaller
        // because the model was fitted to those very points. Showing the flattering one
        // as "accuracy" is how a calibration claims ±20 px and then misses by 150.
        let errorPixels = errorNormalized * ((screenWidth + screenHeight) / 2.0)

        return CalibrationMap(
            schemaVersion: GazeFeatures.schemaVersion,
            isCalibrated: true,
            validationErrorNormalized: errorNormalized,
            validationErrorPixels: errorPixels,
            pointCount: pruned.count,
            residuals: residuals,
            xModel: xModel,
            yModel: yModel,
            basis: basis,
            headBaseline: baseline,
            context: context
        )
    }

    /// Ridge strengths to try, spanning "trust the data" to "barely move off the mean".
    ///
    /// Wide on purpose: the useful value depends on how much the features moved during
    /// the run, and a user who held their head still needs far more shrinkage than one
    /// who moved naturally.
    private static let lambdaCandidates: [Double] = [
        0.001, 0.003, 0.01, 0.03, 0.1, 0.3, 1.0, 3.0, 10.0, 30.0
    ]

    private struct RegularisationChoice {
        let lambda: Double
        let errorNormalized: Double
    }

    /// Chooses the ridge strength whose leave-one-out error is lowest.
    private func selectRegularisation(
        design: [[Double]],
        targetXs: [Double],
        targetYs: [Double]
    ) -> RegularisationChoice {
        var best = RegularisationChoice(lambda: lambda, errorNormalized: .infinity)

        for candidate in Self.lambdaCandidates {
            let regression = RidgeRegression(lambda: candidate)
            guard let xError = regression.crossValidatedError(design: design, targets: targetXs),
                  let yError = regression.crossValidatedError(design: design, targets: targetYs) else {
                continue
            }
            let combined = (xError * xError + yError * yError).squareRoot()
            if combined < best.errorNormalized {
                best = RegularisationChoice(lambda: candidate, errorNormalized: combined)
            }
        }

        // Nothing scored: fall back to the configured value so the caller still gets a
        // map. A calibration that is merely regularised by a guess beats no calibration.
        return best.errorNormalized.isFinite
            ? best
            : RegularisationChoice(lambda: lambda, errorNormalized: .infinity)
    }

    /// Iteratively drops points whose residual is far outside the bulk of the data.
    ///
    /// Median absolute deviation is used rather than standard deviation because the
    /// whole purpose is to be robust to the outliers themselves — a standard deviation
    /// is inflated by the very points we are trying to find.
    private func pruneOutliers(samples: [CalibrationSample]) -> [CalibrationSample] {
        guard samples.count >= minimumSamples + 2 else { return samples }

        var current = samples
        let regression = RidgeRegression(lambda: lambda)

        for _ in 0..<3 {
            let design = current.map { basis.designRow(for: $0.features) }
            guard let xModel = regression.fit(design: design, targets: current.map(\.targetX)),
                  let yModel = regression.fit(design: design, targets: current.map(\.targetY)) else {
                return current
            }

            let distances = current.map { sample -> Double in
                let row = basis.designRow(for: sample.features)
                let dx = xModel.predict(designRow: row) - sample.targetX
                let dy = yModel.predict(designRow: row) - sample.targetY
                return (dx * dx + dy * dy).squareRoot()
            }

            let median = Self.median(distances)
            let deviations = distances.map { abs($0 - median) }
            let mad = Self.median(deviations)

            // A degenerate MAD means the residuals are already tight; nothing to prune.
            guard mad > 1e-9 else { return current }

            let cutoff = median + outlierThresholdMAD * mad
            let kept = zip(current, distances)
                .filter { $0.1 <= cutoff }
                .map(\.0)

            guard kept.count >= minimumSamples else { return current }
            if kept.count == current.count { return current }
            current = kept
        }

        return current
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2.0
        }
        return sorted[middle]
    }
}
