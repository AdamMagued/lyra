import Foundation

/// Decides when a gaze-based selection has earned the right to become the *actual*
/// selection.
///
/// Raw gaze selection flickers. Even with a good tracker the point wanders within a
/// fixation, so the "best target" can alternate between two neighbouring controls
/// several times a second. Acting on that literally produces an interface that clicks
/// things at random. A mouse never has this problem because a hand holds it still.
///
/// The rule is deliberately simple and asymmetric:
///
/// - **Acquiring** a new target requires it to win continuously for `dwellDuration`.
/// - **Releasing** a held target requires a *different* target to win for `switchDuration`,
///   which is longer. Stickiness on the way out is what stops a momentary wobble from
///   pulling focus off the thing the user is deliberately holding.
///
/// Pure logic on an explicit clock, so it can be tested without a camera.
public struct TargetStabilizer: Sendable {

    /// How long a new target must win before it is committed.
    public var dwellDuration: TimeInterval

    /// How long a competing target must win before it displaces a committed one.
    public var switchDuration: TimeInterval

    /// Selections below this confidence are ignored rather than counted as evidence,
    /// so a run of weak frames cannot accumulate into a commit.
    public var minimumConfidence: Double

    /// How long a committed target survives with no matching evidence at all. Covers
    /// blinks and brief tracking dropouts. Beyond this, the user has looked away.
    public var releaseTimeout: TimeInterval

    private var committedCandidate: TargetCandidate?
    private var challengerID: String?
    private var challengerSince: TimeInterval = 0
    private var lastEvidenceAt: TimeInterval?

    public init(
        dwellDuration: TimeInterval = 0.45,
        switchDuration: TimeInterval = 0.7,
        minimumConfidence: Double = 0.3,
        releaseTimeout: TimeInterval = 1.5
    ) {
        self.dwellDuration = dwellDuration
        self.switchDuration = switchDuration
        self.minimumConfidence = minimumConfidence
        self.releaseTimeout = releaseTimeout
    }

    public enum Outcome: Sendable, Equatable {
        /// Nothing selected, nothing in progress worth showing.
        case none
        /// A target is being considered. `progress` is 0...1 towards a commit, for
        /// drawing a dwell ring so the user can watch the selection form.
        case pending(TargetSelection, progress: Double)
        /// A target is committed and can be acted upon.
        case committed(TargetCandidate)
    }

    /// The currently committed target, if any.
    public var committedTarget: TargetCandidate? { committedCandidate }

    /// Feeds one frame of selection evidence and returns the resulting state.
    ///
    /// - Parameters:
    ///   - selection: the current best target, or `nil` if nothing is in range.
    ///   - time: monotonically increasing seconds.
    public mutating func update(selection: TargetSelection?, at time: TimeInterval) -> Outcome {
        // Expire a commitment that has had no support for too long.
        if let lastEvidenceAt, time - lastEvidenceAt > releaseTimeout {
            clearCommitment()
        }

        guard let selection, selection.confidence >= minimumConfidence else {
            // No usable evidence. Hold the current commitment through short gaps
            // (blinks, a dropped frame) rather than dropping the user's selection.
            challengerID = nil
            if let committedCandidate { return .committed(committedCandidate) }
            return .none
        }

        lastEvidenceAt = time
        let candidateID = selection.candidate.id

        // Holding the same target: refresh it.
        if committedCandidate?.id == candidateID {
            committedCandidate = selection.candidate
            challengerID = nil
            return .committed(selection.candidate)
        }

        let requiredDuration = committedCandidate == nil ? dwellDuration : switchDuration
        let isContinuingChallenge = challengerID == candidateID

        if !isContinuingChallenge {
            challengerID = candidateID
            challengerSince = time
        }

        let elapsed = time - challengerSince
        if elapsed >= requiredDuration {
            committedCandidate = selection.candidate
            challengerID = nil
            return .committed(selection.candidate)
        }

        // While a target is held, keep reporting it rather than the challenger, so the
        // UI highlight does not flicker to the thing the user's gaze merely brushed.
        if let committedCandidate { return .committed(committedCandidate) }

        return .pending(selection, progress: elapsed / requiredDuration)
    }

    /// Clears all state, for example when tracking pauses or the app loses focus.
    public mutating func reset() {
        clearCommitment()
        lastEvidenceAt = nil
    }

    private mutating func clearCommitment() {
        committedCandidate = nil
        challengerID = nil
        challengerSince = 0
    }
}
