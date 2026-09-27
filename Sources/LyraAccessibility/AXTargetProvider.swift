import Foundation
import ApplicationServices
import LyraCore

/// macOS implementation of `TargetProvider`: scans the accessibility tree and invokes
/// semantic actions on what it finds.
///
/// The value of going through accessibility rather than clicking coordinates is that the
/// action is *exact*. Pressing a button this way works even if the gaze estimate was
/// 150 points off, because the button was identified by identity, not by position. It
/// also works for controls a coordinate click would miss entirely — anything partially
/// covered, or moved between the sweep and the click.
///
/// Work runs on a dedicated serial queue. Accessibility calls into another process and
/// can block for an unbounded time if that process is busy, so they must never run on
/// the main thread or on the frame pipeline.
public final class AXTargetProvider: TargetProvider, @unchecked Sendable {

    private let scanner: AXTargetScanner
    private let queue = DispatchQueue(label: "com.lyra.accessibility", qos: .userInitiated)

    /// Cached screen size, used for offscreen pruning.
    private let lock = NSLock()
    private var screenSize = LyraSize(width: 1512, height: 982)

    public init(scanner: AXTargetScanner = AXTargetScanner()) {
        self.scanner = scanner
    }

    public func setScreenSize(_ size: LyraSize) {
        lock.lock()
        screenSize = size
        lock.unlock()
    }

    /// Read under the lock, from a *synchronous* context.
    ///
    /// `NSLock.lock()` is unavailable from async code by design — blocking a cooperative
    /// thread is how you deadlock a Swift concurrency pool. Funnelling every read through
    /// this plain method keeps the critical section off the async path entirely.
    private func currentScreenSize() -> LyraSize {
        lock.lock()
        defer { lock.unlock() }
        return screenSize
    }

    public func snapshotTargets() async -> TargetSnapshot {
        let size = currentScreenSize()

        return await withCheckedContinuation { continuation in
            queue.async { [scanner] in
                do {
                    let candidates = try scanner.scan(screenSize: CGSize(width: size.width, height: size.height))
                    continuation.resume(returning: TargetSnapshot(candidates: candidates, screenSize: size))
                } catch {
                    // Permission loss or a wedged target process. Report an empty list
                    // rather than propagating: the coordinator handles "no targets" by
                    // telling the user, which is the right outcome here too.
                    continuation.resume(returning: TargetSnapshot(candidates: [], screenSize: size))
                }
            }
        }
    }

    public func perform(action: TargetCandidate.SemanticAction, on target: TargetSnapshot) async throws {
        guard let candidate = target.candidates.first else {
            throw TargetProviderError.elementUnavailable
        }
        try await perform(action: action, on: candidate)
    }

    /// Performs an action on a specific candidate, resolved through the scanner's cache
    /// so the live element is used rather than a stale reference.
    public func perform(action: TargetCandidate.SemanticAction, on candidate: TargetCandidate) async throws {
        guard let element = scanner.element(for: candidate.id) else {
            throw TargetProviderError.elementUnavailable
        }

        let actionName = Self.accessibilityAction(for: action)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // Ask the element what it supports rather than assuming. Pressing an
                // element that does not implement the action fails silently at the
                // accessibility layer, which would look like a dropped command.
                var supported: CFArray?
                let namesResult = AXUIElementCopyActionNames(element, &supported)

                if namesResult == .success,
                   let names = supported as? [String],
                   !names.contains(actionName) {
                    continuation.resume(throwing: TargetProviderError.actionUnsupported(candidate.role))
                    return
                }

                let result = AXUIElementPerformAction(element, actionName as CFString)
                if result == .success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TargetProviderError.actionUnsupported(candidate.role))
                }
            }
        }
    }

    /// Invalidates the cached tree, for example on application switch.
    public func invalidate() {
        queue.async { [scanner] in
            scanner.invalidate()
        }
    }

    static func accessibilityAction(for action: TargetCandidate.SemanticAction) -> String {
        switch action {
        case .press: return kAXPressAction as String
        case .showMenu: return kAXShowMenuAction as String
        case .confirm: return kAXConfirmAction as String
        case .pick: return kAXPickAction as String
        case .increment: return kAXIncrementAction as String
        case .decrement: return kAXDecrementAction as String
        case .open: return "AXOpen"
        }
    }
}
