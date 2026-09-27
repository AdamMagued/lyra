import Foundation

/// Generates mouse and keyboard events.
///
/// The fallback layer. Per `docs/AGENTS.md` §6 semantic accessibility actions are
/// always preferred, and this exists for the parts of macOS that accessibility does
/// not expose — the Stage Manager thumbnail strip being the example that prompted it.
public protocol InputController: AnyObject, Sendable {
    /// Moves the pointer. Used only when driving the fallback cursor.
    func moveCursor(toScreenPoint point: (x: Double, y: Double)) async throws

    /// Clicks at an absolute screen position, without disturbing the user's real pointer
    /// first. Preferred for target activation.
    func click(atScreenPoint point: (x: Double, y: Double), button: MouseButton) async throws

    func doubleClick(atScreenPoint point: (x: Double, y: Double)) async throws

    /// Sends a key combination. Reserved for editor-style integrations.
    func sendKeystroke(key: KeyCode, modifiers: KeyModifiers) async throws
}

/// A platform-neutral virtual key identifier.
///
/// Deliberately an opaque box rather than a raw `CGKeyCode`: the meaning of a key code is
/// platform-specific, but the *concept* of "press this key" is not, and keeping the
/// platform type out of the core is what lets the command layer stay shared.
public struct KeyCode: Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
}

public enum MouseButton: Sendable {
    case left
    case right
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}
