import Foundation

/// Sources raw facial measurements from a camera.
///
/// Note what this protocol does *not* do: it never returns a screen position. A gaze
/// provider has no idea where the screen is, and deliberately so. Keeping "measure the
/// face" and "work out where the user is looking" in separate modules is what makes the
/// calibration math testable without hardware, and it is the boundary the original
/// implementation blurred when the estimator emitted a screen point directly.
public protocol GazeProvider: AnyObject, Sendable {
    /// Continuous stream of per-frame measurements. Emits only frames where a face was
    /// found; unusable frames still arrive, marked via `GazeFeatures.isUsable`, so the
    /// consumer can distinguish "blinked" from "camera stopped".
    var featureStream: AsyncStream<GazeFeatures> { get }

    /// Whether a face is currently being detected at all.
    var isTracking: Bool { get async }

    func start() async throws
    func stop() async
}
