import Foundation

/// Decides when the lens should open on its own.
///
/// The problem this solves: a webcam gaze estimate is off by roughly the height of a
/// line of text. Looking straight at a toolbar of 20-point icons therefore cannot
/// select one — not because the maths is wrong, but because the hardware is not that
/// precise. Waiting for the user to say "zoom" works, but it makes them diagnose the
/// problem and issue a command before they can do the thing they already tried to do by
/// looking at it.
///
/// So the lens opens when the user's own behaviour says it is needed: their gaze has
/// settled on a place where several small controls sit close together. That is exactly
/// the situation where direct selection is unreliable and magnification helps, and it is
/// detectable without knowing the calibration error at all.
///
/// Three details make this usable rather than twitchy:
///
/// - **Dwell to open.** A cluster only counts once the gaze has stayed on it. Glancing
///   across a toolbar on the way somewhere else must not pop a panel open.
/// - **Looking away to close, not looking away from the cluster.** Once the lens is up,
///   the user *must* move their gaze onto it to choose a row, so "gaze left the cluster"
///   would close it instantly. Closing keys off the lens panel instead.
/// - **A cooldown after closing.** Otherwise the gaze drifts back towards where the
///   cluster was, the lens reopens, and the user is trapped in a loop they cannot exit.
public struct AutoLensPolicy: Sendable {

    /// Master switch. Off means the lens only opens on an explicit "zoom".
    public var isEnabled: Bool

    /// How far from the gaze point a control can be and still count as competing for it.
    ///
    /// This is a **floor**, not the value used. The real radius comes from the measured
    /// calibration error, because that is the quantity that decides whether two controls
    /// are actually ambiguous: two thumbnails 8 points apart are a coin flip for a tracker
    /// that misses by 100 points and a non-issue for one that misses by 5. A fixed radius
    /// would have to guess, and would be wrong for most users.
    public var clusterRadius: Double

    /// Minimum number of controls before this counts as a cluster. One small control is
    /// a targeting problem; two or more competing for the same gaze is a targeting
    /// *ambiguity*, which is the case the lens actually resolves.
    public var minimumTargets: Int

    /// How long the gaze must hold on a cluster before the lens opens.
    public var dwellToOpen: TimeInterval

    /// How long the gaze must be off the lens before it closes.
    public var dwellToClose: TimeInterval

    /// How long to wait after closing before it may open again.
    public var cooldown: TimeInterval

    public init(
        isEnabled: Bool = true,
        clusterRadius: Double = 130,
        minimumTargets: Int = 2,
        dwellToOpen: TimeInterval = 0.35,
        dwellToClose: TimeInterval = 1.1,
        cooldown: TimeInterval = 1.5
    ) {
        self.isEnabled = isEnabled
        self.clusterRadius = clusterRadius
        self.minimumTargets = minimumTargets
        self.dwellToOpen = dwellToOpen
        self.dwellToClose = dwellToClose
        self.cooldown = cooldown
    }

    public static let `default` = AutoLensPolicy()
}

/// Tracks whether the lens should be open, given a stream of gaze samples.
///
/// Pure and clock-driven: the caller supplies the time, so the whole policy is testable
/// without a camera or a screen.
public struct AutoLensTracker: Sendable {

    public var policy: AutoLensPolicy

    private var clusterSince: TimeInterval?
    private var awaySince: TimeInterval?
    private var closedAt: TimeInterval = -.infinity

    public init(policy: AutoLensPolicy = .default) {
        self.policy = policy
    }

    public private(set) var isOpen = false

    /// Whether the controls under the gaze are competing for it.
    ///
    /// Non-actionable targets are ignored: a cluster of labels with nothing clickable
    /// among them is not something the lens can help with, since the lens exists to
    /// choose between things that can be acted on.
    ///
    /// - Parameter radius: how far a control can be from the gaze point and still count as
    ///   a plausible target. The caller supplies the measured tracker error here, well
    ///   short of it the lens would open over controls that were never in doubt.
    public func isCluster(
        gazePoint: LyraPoint,
        candidates: [TargetCandidate],
        radius: Double
    ) -> Bool {
        guard policy.isEnabled else { return false }

        let nearby = candidates.filter { candidate in
            candidate.isActionable
                && candidate.frame.distance(to: gazePoint) <= max(radius, policy.clusterRadius)
        }

        return nearby.count >= policy.minimumTargets
    }

    /// Call once per gaze frame while the lens is closed.
    ///
    /// - Returns: `true` on the frame the lens should open.
    public mutating func updateClosed(
        gazePoint: LyraPoint,
        candidates: [TargetCandidate],
        radius: Double,
        at time: TimeInterval
    ) -> Bool {
        guard policy.isEnabled, !isOpen else { return false }
        guard time - closedAt >= policy.cooldown else { return false }

        guard isCluster(gazePoint: gazePoint, candidates: candidates, radius: radius) else {
            clusterSince = nil
            return false
        }

        guard let since = clusterSince else {
            clusterSince = time
            return false
        }

        if time - since >= policy.dwellToOpen {
            isOpen = true
            clusterSince = nil
            awaySince = nil
            return true
        }
        return false
    }

    /// Call once per gaze frame while the lens is open.
    ///
    /// - Returns: `true` on the frame the lens should close.
    public mutating func updateOpen(
        gazePoint: LyraPoint,
        lensPanel: LyraRect,
        at time: TimeInterval
    ) -> Bool {
        // Generous margin: the user aiming at the top or bottom row should not be
        // treated as having left the lens because their gaze overshot the panel edge by
        // a tracker error's worth.
        let forgiving = lensPanel.insetBy(dx: -70, dy: -70)

        guard !forgiving.contains(gazePoint) else {
            awaySince = nil
            return false
        }

        guard let since = awaySince else {
            awaySince = time
            return false
        }

        if time - since >= policy.dwellToClose {
            close(at: time)
            return true
        }
        return false
    }

    /// Closes the lens because something else happened — a row was activated, the user
    /// said "cancel", and so on.
    public mutating func close(at time: TimeInterval) {
        isOpen = false
        closedAt = time
        clusterSince = nil
        awaySince = nil
    }

    public mutating func reset() {
        isOpen = false
        clusterSince = nil
        awaySince = nil
        closedAt = -.infinity
    }
}
