import Foundation

/// Chooses which on-screen target a gaze point refers to.
///
/// This is where the product stops needing pixel-accurate gaze. A webcam tracker lands
/// within roughly 100-200 points of the true gaze position, which is hopeless for
/// driving a pointer but entirely adequate for answering "which control is the user
/// looking at?" — as long as the answer is chosen with that error budget in mind.
///
/// The rules, in order:
///
/// 1. Any actionable candidate containing the gaze point wins, smallest first. Smallest
///    rather than deepest, because a button nested in a toolbar nested in a window all
///    contain the point, and the smallest of them is the one under the user's eye.
/// 2. Failing that, the nearest candidate within `snapRadius`. Gaze error is why this
///    exists: requiring the gaze to land *inside* a 20-point-tall menu row would fail
///    constantly, whereas snapping from 60 points away almost always gets it right.
/// 3. Non-actionable candidates are only considered if nothing actionable is in range,
///    so a decorative label never steals a selection from a button.
public struct TargetResolver: Sendable {

    /// How far outside a target a gaze may land and still select it, in points.
    /// Should be in the same ballpark as the tracker's real error — too small and
    /// selection feels impossible, too large and neighbouring controls steal focus.
    public var snapRadius: Double

    /// Candidates larger than this fraction of the screen are treated as containers
    /// (windows, scroll areas) and deprioritised, because selecting the whole window
    /// is never what the user meant.
    public var containerAreaFraction: Double

    public init(snapRadius: Double = 70.0, containerAreaFraction: Double = 0.45) {
        self.snapRadius = snapRadius
        self.containerAreaFraction = containerAreaFraction
    }

    /// Resolves the best target for a gaze point given in screen coordinates.
    ///
    /// - Parameters:
    ///   - gazePoint: screen position in points, origin top-left.
    ///   - candidates: everything currently on screen.
    ///   - screenSize: used to classify container-sized candidates.
    ///   - gazeConfidence: confidence of the underlying gaze sample, 0...1.
    public func resolve(
        gazePoint: LyraPoint,
        candidates: [TargetCandidate],
        screenSize: LyraSize,
        gazeConfidence: Double
    ) -> TargetSelection? {
        guard !candidates.isEmpty else { return nil }

        let containerArea = screenSize.area * containerAreaFraction

        func isContainer(_ candidate: TargetCandidate) -> Bool {
            candidate.area > containerArea
        }

        // Tier 1: contained, actionable, smallest wins.
        let containing = candidates.filter {
            $0.isActionable && $0.frame.contains(gazePoint)
        }
        if let best = containing.min(by: { lhs, rhs in
            if isContainer(lhs) != isContainer(rhs) { return !isContainer(lhs) }
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return lhs.depth > rhs.depth
        }) {
            return TargetSelection(
                candidate: best,
                distance: 0,
                confidence: gazeConfidence
            )
        }

        // Tier 2: nearest in range. Actionable targets are strongly preferred, but a
        // non-actionable one still beats selecting nothing when it is much closer —
        // it lets the UI show "you are looking at this, but it cannot be clicked".
        let ranked = candidates
            .map { candidate -> (TargetCandidate, Double) in
                (candidate, candidate.frame.distance(to: gazePoint))
            }
            .filter { $0.1 <= snapRadius }
            .sorted { lhs, rhs in
                let lhsContainer = isContainer(lhs.0)
                let rhsContainer = isContainer(rhs.0)
                if lhsContainer != rhsContainer { return !lhsContainer }

                if lhs.0.isActionable != rhs.0.isActionable {
                    // Only defer to a non-actionable target if it is dramatically closer.
                    if lhs.0.isActionable { return true }
                    return lhs.1 + snapRadius * 0.5 < rhs.1
                }

                if abs(lhs.1 - rhs.1) > 1.0 { return lhs.1 < rhs.1 }
                return lhs.0.area < rhs.0.area
            }

        guard let (candidate, distance) = ranked.first else { return nil }

        // Confidence falls off with how far outside the target the gaze landed, so a
        // marginal snap is visibly less certain than a direct hit.
        let proximity = max(0.0, 1.0 - distance / snapRadius)
        let combined = gazeConfidence * (0.45 + 0.55 * proximity)

        return TargetSelection(candidate: candidate, distance: distance, confidence: combined)
    }
}
