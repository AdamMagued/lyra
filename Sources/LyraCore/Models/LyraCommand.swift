import Foundation

/// Canonical deterministic commands recognised by Lyra.
///
/// Per `docs/AGENTS.md` §8 a transcript is never itself an action: speech is normalised,
/// then parsed into one of these, and only then does the control plane consider acting.
///
/// The vocabulary has changed shape from the original cursor-control set. Because gaze
/// now *selects* rather than *points*, most commands act on "the currently selected
/// target" and never mention coordinates at all. That is what makes the system tolerant
/// of imperfect gaze: the action lands on a semantic element, not on a pixel.
public enum LyraCommand: Sendable, Equatable {
    /// Begin tracking ("cursor", "start tracking", "track").
    case startTracking

    /// Suspend tracking immediately ("stop", "off", "pause", "halt").
    case stopTracking

    /// Activate the currently selected target ("click", "pick", "select", "press").
    case activate
    case doubleClick
    case rightClick

    /// Cycle the selection when gaze picked the wrong thing ("next", "next one", "other").
    case nextTarget
    case previousTarget

    /// Reveal every pickable target, so the user can see what is available.
    case showTargets
    case hideTargets

    /// Magnify the region around the current gaze point for finer picking.
    case zoomIn
    case zoomOut

    /// Undo the last activation where the target supports it.
    case undo

    /// Dismiss the current selection without acting ("cancel", "never mind", "clear").
    case cancel

    /// Answer a pending confirmation ("yes", "confirm", "go ahead").
    case confirm

    /// Explicitly denied confirmation ("no", "don't", "abort").
    case deny

    /// Raw unhandled speech or unrecognised command.
    case unrecognized(String)
}
