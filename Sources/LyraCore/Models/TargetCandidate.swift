import Foundation

/// Something on screen that gaze can select.
///
/// Targets come from two sources, and the distinction is load-bearing:
///
/// - **Accessibility elements** — real buttons, fields, menu items. Selecting one gives
///   us a semantic action (`press`, `setValue`), which executes with zero positional
///   error because we never touch a coordinate.
/// - **Screen regions** — things macOS does not expose to accessibility at all. The Dock's
///   Stage Manager thumbnails, canvas content, and a surprising number of system UI
///   surfaces land here. For these the only option is a coordinate click.
///
/// Following `docs/AGENTS.md` §6, accessibility is always preferred and coordinates are
/// the fallback, but the fallback has to genuinely exist or whole parts of the system
/// become unreachable by gaze — which is exactly what the user noticed about Stage Manager.
public struct TargetCandidate: Sendable, Identifiable, Equatable {

    public enum Source: String, Sendable, Codable {
        /// A semantic macOS accessibility element.
        case accessibility
        /// A region with no accessibility representation; clickable by coordinate only.
        case screenRegion
    }

    /// Stable identity, so the same element can be tracked across frames without flicker.
    public let id: String

    /// Bounding box in screen coordinates, points, origin top-left.
    public let frame: LyraRect

    /// Best available human-readable name. May be empty for unlabelled regions.
    public let label: String

    /// Accessibility role (for example `AXButton`, `AXTextField`), or a synthetic
    /// descriptor for screen regions.
    public let role: String

    public let source: Source

    /// Depth in the accessibility hierarchy. Deeper elements are more specific,
    /// which is how we choose between a button and the window containing it.
    public let depth: Int

    /// Whether we have a way to actually act on this.
    public let isActionable: Bool

    /// The semantic action to invoke, when one is available.
    public let action: SemanticAction?

    public enum SemanticAction: String, Sendable, Codable {
        case press
        case showMenu
        case confirm
        case pick
        case increment
        case decrement
        case open
    }

    public init(
        id: String,
        frame: LyraRect,
        label: String,
        role: String,
        source: Source,
        depth: Int,
        isActionable: Bool,
        action: SemanticAction?
    ) {
        self.id = id
        self.frame = frame
        self.label = label
        self.role = role
        self.source = source
        self.depth = depth
        self.isActionable = isActionable
        self.action = action
    }

    public var area: Double {
        frame.area
    }

    /// Short description for the overlay and the voice confirmation.
    public var displayName: String {
        if !label.isEmpty { return label }
        switch source {
        case .accessibility: return role
        case .screenRegion: return "screen region"
        }
    }
}

/// A target chosen for a gaze position, with the reasoning behind the choice retained
/// so the UI can show *why* something was selected.
public struct TargetSelection: Sendable, Equatable {
    public let candidate: TargetCandidate
    /// Distance from the gaze point to the target, in points. Zero when the gaze
    /// landed inside the element.
    public let distance: Double
    /// 0...1, combining gaze confidence with how well the gaze actually landed on
    /// the target. Low values should visibly warn the user rather than silently act.
    public let confidence: Double

    public init(candidate: TargetCandidate, distance: Double, confidence: Double) {
        self.candidate = candidate
        self.distance = distance
        self.confidence = confidence
    }
}
