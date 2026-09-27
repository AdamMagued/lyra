import Foundation

/// Classifies commands by how much damage a mistake would do.
///
/// `docs/AGENTS.md` §9 requires every command to have a risk policy, and the reasoning
/// is concrete rather than bureaucratic: Lyra's input is a webcam and a microphone, both
/// of which mishear. The cost of a false positive is not a wasted click, it is someone
/// losing work they cannot easily restore.
///
/// Note that risk here is about *reversibility*, not about how scary the word sounds.
/// A click is normally harmless because it is trivially undone, but the same click on a
/// Delete button is not — which is why the classification considers the target, not just
/// the command.
public struct RiskPolicy: Sendable {

    public enum Risk: Int, Sendable, Comparable {
        case low
        case medium
        case high

        public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public init() {}

    /// Risk of a command in isolation, ignoring what it will act on.
    public func risk(of command: LyraCommand) -> Risk {
        switch command {
        case .startTracking, .stopTracking, .cancel, .deny,
             .nextTarget, .previousTarget, .zoomIn, .zoomOut,
             .showTargets, .hideTargets, .confirm:
            return .low

        case .activate, .doubleClick, .rightClick:
            return .low

        case .undo:
            return .medium

        case .unrecognized:
            return .low
        }
    }

    /// Risk of acting on a specific target, which can be higher than the command alone.
    ///
    /// A double click on an arbitrary button is low risk. The same double click on a
    /// control whose label reads like a destructive action is not, and the user should
    /// have to mean it.
    public func risk(of command: LyraCommand, on target: TargetCandidate?) -> Risk {
        let base = risk(of: command)
        guard let target else { return base }

        if Self.destructiveLabelMarkers.contains(where: { target.label.localizedCaseInsensitiveContains($0) }) {
            return .high
        }
        return base
    }

    /// Whether a command should require an explicit spoken confirmation before executing.
    public func requiresConfirmation(_ command: LyraCommand, on target: TargetCandidate?) -> Bool {
        risk(of: command, on: target) >= .high
    }

    /// Whether acting on a stale target snapshot is acceptable. It never is for
    /// anything that changes state, because the element may have moved or vanished.
    public func allowsStaleTarget(_ command: LyraCommand) -> Bool {
        risk(of: command) == .low && command == .nextTarget
    }

    /// Labels that mark a control as irreversible-enough to warrant confirming.
    ///
    /// Deliberately conservative and deliberately small. An over-eager list makes the
    /// product exhausting to use, and a user who is asked to confirm everything stops
    /// reading the confirmations — which is worse than asking for none.
    private static let destructiveLabelMarkers: [String] = [
        "delete", "erase", "remove", "format", "uninstall",
        "empty trash", "empty the trash", "discard", "reset",
        "sign out", "log out", "shut down", "restart", "erase all",
        "send", "publish", "post", "submit payment", "buy", "purchase"
    ]
}
