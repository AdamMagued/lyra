import Foundation
import CoreGraphics
import LyraCore

public enum InputError: Error, LocalizedError {
    case accessibilityNotGranted
    case eventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Lyra needs Accessibility permission to control the pointer."
        case .eventCreationFailed:
            return "Could not generate a mouse event."
        }
    }
}

/// Generates CoreGraphics events.
///
/// The fallback path, used only for the parts of macOS that accessibility does not
/// expose. Because a coordinate click carries no verification that the intended control
/// is still there, callers are expected to prefer a semantic action and to reach for
/// this only when none exists.
///
/// Note that clicks are posted with an explicit location rather than by moving the real
/// pointer first. That matters: warping the cursor and clicking works, but it makes the
/// user's pointer jump around the screen as a side effect of every action, which is
/// disorienting and makes it impossible to use the mouse at the same time.
public final class CGInputController: InputController, @unchecked Sendable {

    private let eventSource: CGEventSource?

    public init() {
        // Private state rather than combined session state, so events are not affected by
        // whatever modifier keys the user happens to be holding.
        self.eventSource = CGEventSource(stateID: .privateState)
    }

    public func moveCursor(toScreenPoint point: (x: Double, y: Double)) async throws {
        let target = CGPoint(x: point.x, y: point.y)
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), target)

        if let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
    }

    public func click(atScreenPoint point: (x: Double, y: Double), button: MouseButton) async throws {
        let location = CGPoint(x: point.x, y: point.y)
        let (downType, upType): (CGEventType, CGEventType) = button == .left
            ? (.leftMouseDown, .leftMouseUp)
            : (.rightMouseDown, .rightMouseUp)
        let cgButton: CGMouseButton = button == .left ? .left : .right

        guard let down = CGEvent(mouseEventSource: eventSource, mouseType: downType, mouseCursorPosition: location, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: eventSource, mouseType: upType, mouseCursorPosition: location, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }

        down.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 30_000_000)
        up.post(tap: .cghidEventTap)
    }

    public func doubleClick(atScreenPoint point: (x: Double, y: Double)) async throws {
        let location = CGPoint(x: point.x, y: point.y)

        guard let downOne = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
              let upOne = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left),
              let downTwo = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
              let upTwo = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else {
            throw InputError.eventCreationFailed
        }

        // The click-state field is what tells an application these two clicks are one
        // double click rather than two separate single clicks.
        downOne.setIntegerValueField(.mouseEventClickState, value: 1)
        upOne.setIntegerValueField(.mouseEventClickState, value: 1)
        downTwo.setIntegerValueField(.mouseEventClickState, value: 2)
        upTwo.setIntegerValueField(.mouseEventClickState, value: 2)

        downOne.post(tap: .cghidEventTap)
        upOne.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 40_000_000)
        downTwo.post(tap: .cghidEventTap)
        upTwo.post(tap: .cghidEventTap)
    }

    public func sendKeystroke(key: KeyCode, modifiers: KeyModifiers) async throws {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(key.rawValue), keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(key.rawValue), keyDown: false) else {
            throw InputError.eventCreationFailed
        }

        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
