import Foundation

/// Supplies the set of things on screen that gaze can select, and performs the
/// resulting actions.
///
/// This is the interface that makes Lyra a target picker rather than a mouse
/// replacement. Platforms differ completely in how they expose on-screen controls —
/// macOS uses `AXUIElement`, Windows uses UI Automation, Linux uses AT-SPI — but they
/// all reduce to the same two operations: *list the pickable things* and *act on one*.
/// Keeping the difference behind this protocol is what lets the targeting logic,
/// the safety policy, and the whole command layer stay shared.
public protocol TargetProvider: AnyObject, Sendable {

    /// Captures the currently pickable targets, in screen coordinates.
    ///
    /// Called on a cadence rather than per gaze frame: walking an accessibility tree is
    /// far too expensive to do at 60 Hz, and controls do not move that often.
    func snapshotTargets() async -> TargetSnapshot

    /// Performs a semantic action on a target.
    ///
    /// Throws when the action is not supported by the element. Callers must be prepared
    /// to fall back to a coordinate click, and must surface the failure rather than
    /// silently doing nothing.
    func perform(action: TargetCandidate.SemanticAction, on target: TargetSnapshot) async throws
}

/// A captured set of targets, tagged with when it was taken.
///
/// The timestamp matters for safety: acting on a stale snapshot can mean clicking a
/// button that has since disappeared or moved, so the coordinator refuses to execute
/// against snapshots older than a short freshness window.
public struct TargetSnapshot: Sendable {
    public let candidates: [TargetCandidate]
    public let capturedAt: Date
    /// Screen the snapshot was taken on.
    public let screenSize: LyraSize

    public init(candidates: [TargetCandidate], capturedAt: Date = Date(), screenSize: LyraSize) {
        self.candidates = candidates
        self.capturedAt = capturedAt
        self.screenSize = screenSize
    }

    public var age: TimeInterval { Date().timeIntervalSince(capturedAt) }

    public static let empty = TargetSnapshot(candidates: [], screenSize: LyraSize(width: 0, height: 0))
}

public enum TargetProviderError: Error, LocalizedError {
    case elementUnavailable
    case actionUnsupported(String)
    case accessibilityNotGranted

    public var errorDescription: String? {
        switch self {
        case .elementUnavailable:
            return "That control is no longer on screen."
        case .actionUnsupported(let role):
            return "This control (\(role)) does not support that action. Lyra can still click it directly."
        case .accessibilityNotGranted:
            return "Lyra needs Accessibility permission to see the controls on your screen."
        }
    }
}
