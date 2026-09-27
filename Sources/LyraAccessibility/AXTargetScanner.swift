import Foundation
import ApplicationServices
import LyraCore

/// Walks the macOS accessibility tree and produces the list of things gaze can select.
///
/// This is the layer that lets Lyra stop needing pixel-accurate gaze. Once a control is
/// a real accessibility element, activating it is exact — macOS presses the button,
/// no coordinate is involved, and a 150-point gaze error costs nothing.
///
/// The hard part is not reading the tree, it is reading it *fast enough*. A full walk of
/// a busy application can take hundreds of milliseconds, which is far too slow to run
/// per frame. Three things keep it tractable:
///
/// - **Depth and count limits.** Deeply nested content is rarely what a user is aiming at,
///   and unbounded walks on a large document can effectively hang.
/// - **Offscreen pruning.** A subtree whose root is not on screen cannot contain anything
///   the user is looking at, so it is skipped entirely — this is where most of the
///   saving comes from in apps with long scrollable content.
/// - **Attribute batching.** Children are fetched in one call per parent rather than
///   one call per child.
///
/// Elements are cached between sweeps so an action can be performed on the element that
/// was actually seen, rather than on whatever now occupies the same coordinates.
public final class AXTargetScanner: @unchecked Sendable {

    // MARK: - Limits

    public struct Limits: Sendable {
        public var maximumDepth: Int
        public var maximumElements: Int
        public var maximumChildrenPerNode: Int

        public init(maximumDepth: Int = 14, maximumElements: Int = 2500, maximumChildrenPerNode: Int = 120) {
            self.maximumDepth = maximumDepth
            self.maximumElements = maximumElements
            self.maximumChildrenPerNode = maximumChildrenPerNode
        }

        public static let `default` = Limits()
    }

    private let limits: Limits
    private let lock = NSLock()

    /// id -> live element, refreshed on every sweep. Used to act on what was seen.
    private var elementCache: [String: AXUIElement] = [:]

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    public enum ScanError: Error, LocalizedError {
        case notTrusted

        public var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Lyra needs Accessibility permission to see the controls on your screen."
            }
        }
    }

    /// Performs a full sweep and returns the pickable targets.
    ///
    /// - Parameters:
    ///   - screenSize: used to prune anything outside the visible area.
    ///   - includeSystemUI: whether to also scan the system-wide tree, which is what
    ///     exposes the menu bar and the Dock. Slightly slower, considerably more useful.
    public func scan(screenSize: CGSize, includeSystemUI: Bool = true) throws -> [TargetCandidate] {
        guard AXIsProcessTrusted() else { throw ScanError.notTrusted }

        var candidates: [TargetCandidate] = []
        var cache: [String: AXUIElement] = [:]
        var identifierCounts: [String: Int] = [:]

        let screenBounds = CGRect(origin: .zero, size: screenSize)

        func visit(_ element: AXUIElement, depth: Int, pid: pid_t) {
            guard candidates.count < limits.maximumElements else { return }
            guard depth <= limits.maximumDepth else { return }

            if depth > 0,
               let candidate = makeCandidate(
                   from: element,
                   pid: pid,
                   depth: depth,
                   screenBounds: screenBounds,
                   identifierCounts: &identifierCounts
               ) {
                candidates.append(candidate)
                cache[candidate.id] = element
            }

            // Prune before descending: a subtree that is hidden or minimised cannot
            // contain the target and is the main cost in large applications.
            if depth > 0, isPrunable(element) { return }

            for child in children(of: element) {
                visit(child, depth: depth + 1, pid: pid)
            }
        }

        // The system-wide element exposes the menu bar, the Dock and other chrome that
        // belongs to no single application.
        if includeSystemUI {
            let systemWide = AXUIElementCreateSystemWide()
            visit(systemWide, depth: 0, pid: 0)
        }

        if let focusedApp = focusedApplication() {
            var appPid: pid_t = 0
            AXUIElementGetPid(focusedApp, &appPid)
            visit(focusedApp, depth: 0, pid: appPid)
        }

        lock.lock()
        elementCache = cache
        lock.unlock()

        return candidates
    }

    /// Forgets the cached tree, for example when the frontmost application changes.
    public func invalidate() {
        lock.lock()
        elementCache.removeAll()
        lock.unlock()
    }

    /// Returns the live element for a previously reported candidate id.
    public func element(for identifier: String) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return elementCache[identifier]
    }

    // MARK: - Element inspection

    private func focusedApplication() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let application = value else { return nil }
        return (application as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        if array.count <= limits.maximumChildrenPerNode { return array }
        return Array(array.prefix(limits.maximumChildrenPerNode))
    }

    /// Whether a subtree can be skipped without missing anything visible.
    private func isPrunable(_ element: AXUIElement) -> Bool {
        if let hidden = boolAttribute(element, kAXHiddenAttribute as CFString), hidden { return true }
        if let minimised = boolAttribute(element, "AXMinimized" as CFString), minimised { return true }
        return false
    }

    private func makeCandidate(
        from element: AXUIElement,
        pid: pid_t,
        depth: Int,
        screenBounds: CGRect,
        identifierCounts: inout [String: Int]
    ) -> TargetCandidate? {
        guard let frame = frame(of: element) else { return nil }

        // Ignore degenerate and offscreen geometry. Tiny frames are usually layout
        // artefacts rather than controls anyone would aim at.
        guard frame.width >= 6, frame.height >= 6 else { return nil }
        guard frame.intersects(screenBounds) else { return nil }

        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""

        // Roles without a semantic action are still reported: the interface can then say
        // "you are looking at this, but it cannot be clicked", and the lens can list it
        // for context. They are marked non-actionable so they never win a selection
        // against a real control.
        let capability = Self.capability(for: role)
        let label = bestLabel(element: element, role: role)

        let baseIdentifier = Self.identifier(pid: pid, role: role, frame: frame, label: label)
        let occurrence = identifierCounts[baseIdentifier, default: 0]
        identifierCounts[baseIdentifier] = occurrence + 1
        let uniqueIdentifier = occurrence == 0 ? baseIdentifier : "\(baseIdentifier)#\(occurrence)"

        return TargetCandidate(
            id: uniqueIdentifier,
            frame: Self.portable(frame),
            label: label,
            role: role,
            source: .accessibility,
            depth: depth,
            isActionable: capability != nil,
            action: capability
        )
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute as CFString),
              let size = sizeAttribute(element, kAXSizeAttribute as CFString) else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }
        // Accessibility positions are already top-left origin global screen coordinates,
        // which is the convention the rest of Lyra uses.
        return CGRect(origin: position, size: size)
    }

    private func bestLabel(element: AXUIElement, role: String) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXHelp"] {
            if let value = stringAttribute(element, attribute as CFString),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Values can be enormous (a whole text field's contents). Truncate so
                // the overlay has something sane to render.
                return String(value.prefix(80))
            }
        }
        return Self.humanReadable(role: role)
    }

    // MARK: - Attribute helpers

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? Bool else { return nil }
        return number
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - Role knowledge

    /// Maps an accessibility role to the semantic action worth invoking.
    ///
    /// Roles not listed here are still reported, just as non-actionable. That is
    /// deliberate: a container is useful context ("you are looking at the sidebar") and
    /// showing it is better than showing nothing, but it must never win a selection
    /// against a real button.
    static func capability(for role: String) -> TargetCandidate.SemanticAction? {
        switch role {
        case "AXButton", "AXToggle", "AXTab", "AXRadioButton", "AXCheckBox",
             "AXDisclosureTriangle", "AXMenuButton", "AXPopUpButton", "AXComboBox":
            return .press
        case "AXMenuItem", "AXMenuBarItem":
            return .press
        case "AXMenu":
            return .showMenu
        case "AXLink":
            return .press
        case "AXTextField", "AXTextArea", "AXSearchField":
            return .confirm
        case "AXSlider":
            return .increment
        case "AXIncrementor", "AXStepper":
            return .increment
        case "AXRow", "AXCell", "AXOutlineRow":
            return .pick
        case "AXImage", "AXIcon":
            // Icons are frequently the only accessible thing inside a custom control.
            return .press
        case "AXDockItem":
            return .press
        default:
            return nil
        }
    }

    static func humanReadable(role: String) -> String {
        guard role.hasPrefix("AX") else { return role }
        let trimmed = role.dropFirst(2)
        // Split "MenuBarItem" into "Menu Bar Item".
        var words: [String] = []
        var current = ""
        for character in trimmed {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    static func identifier(pid: pid_t, role: String, frame: CGRect, label: String) -> String {
        let x = Int(frame.origin.x.rounded())
        let y = Int(frame.origin.y.rounded())
        let w = Int(frame.width.rounded())
        let h = Int(frame.height.rounded())
        return "\(pid)|\(role)|\(x),\(y),\(w),\(h)|\(label.prefix(24))"
    }

    /// Bridges CoreGraphics geometry into Lyra's portable equivalent.
    ///
    /// The conversion lives here rather than in `LyraCore` on purpose: the shared layer
    /// must not know that CoreGraphics exists, or it stops being shareable with the
    /// Windows and Linux builds.
    static func portable(_ rect: CGRect) -> LyraRect {
        LyraRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}
