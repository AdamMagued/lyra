import XCTest
@testable import LyraCore

/// The coordinator's lifecycle contract.
///
/// This file exists because of a real bug. `LyraCoordinator.start()` sets
/// `isEngineRunning` and publishes it, but the *published mirror* the app view model
/// holds is fed by an async task consuming that stream — so it lags. The view model
/// checked the mirror immediately after awaiting `start()`, read a stale `false`, and
/// cancelled the calibration it had just begun. Calibration therefore failed on the first
/// run after every launch, which is precisely when the engine is not running yet.
///
/// The fix was to ask the coordinator instead of the mirror. That only works if
/// `currentSnapshot` reflects a completed `start()` the instant it returns, so that is
/// what these tests pin down.
final class CoordinatorTests: XCTestCase {

    // MARK: - Doubles

    private final class FakeGazeProvider: GazeProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _isTracking = false
        private var continuation: AsyncStream<GazeFeatures>.Continuation?

        var startError: Error?

        var featureStream: AsyncStream<GazeFeatures> {
            AsyncStream { continuation in self.continuation = continuation }
        }

        // Synchronous accessors: `NSLock.lock()` is unavailable directly inside an async
        // function, so the critical section is reached through these.
        private func readTracking() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return _isTracking
        }

        private func writeTracking(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            _isTracking = value
        }

        var isTracking: Bool { readTracking() }

        func start() async throws {
            if let startError { throw startError }
            writeTracking(true)
        }

        func stop() async {
            writeTracking(false)
        }
    }

    private final class FakeSpeechProvider: SpeechProvider, @unchecked Sendable {
        var transcriptStream: AsyncStream<Transcript> {
            AsyncStream { _ in }
        }
        func start() async throws {}
        func stop() async {}
    }

    private final class FakeTargetProvider: TargetProvider, @unchecked Sendable {
        func snapshotTargets() async -> TargetSnapshot {
            TargetSnapshot(candidates: [], screenSize: LyraSize(width: 1470, height: 956))
        }
        func perform(action: TargetCandidate.SemanticAction, on target: TargetSnapshot) async throws {}
    }

    private final class FakeInputController: InputController, @unchecked Sendable {
        func moveCursor(toScreenPoint point: (x: Double, y: Double)) async throws {}
        func click(atScreenPoint point: (x: Double, y: Double), button: MouseButton) async throws {}
        func doubleClick(atScreenPoint point: (x: Double, y: Double)) async throws {}
        func sendKeystroke(key: KeyCode, modifiers: KeyModifiers) async throws {}
    }

    private func makeCoordinator(
        gaze: FakeGazeProvider = FakeGazeProvider()
    ) -> LyraCoordinator {
        LyraCoordinator(
            gazeProvider: gaze,
            speechProvider: FakeSpeechProvider(),
            targetProvider: FakeTargetProvider(),
            inputController: FakeInputController()
        )
    }

    // MARK: - Lifecycle

    func testStartIsVisibleInTheSnapshotAsSoonAsItReturns() async throws {
        let coordinator = makeCoordinator()

        var running = await coordinator.currentSnapshot.isEngineRunning
        XCTAssertFalse(running)

        try await coordinator.start()

        // No sleep, no polling. Anything that needs to know the engine is up reads this
        // straight after awaiting `start()`, and the whole point is that it can.
        running = await coordinator.currentSnapshot.isEngineRunning
        XCTAssertTrue(running, "start() must leave currentSnapshot showing a running engine")
    }

    func testStartIsIdempotent() async throws {
        // The view model calls `start()` unconditionally before calibrating rather than
        // asking whether the engine is already up, because asking is what broke. Starting
        // twice must therefore be harmless.
        let coordinator = makeCoordinator()
        try await coordinator.start()
        try await coordinator.start()
        let running = await coordinator.currentSnapshot.isEngineRunning
        XCTAssertTrue(running)
    }

    func testAFailedStartLeavesTheEngineStopped() async throws {
        let gaze = FakeGazeProvider()
        gaze.startError = GazeErrorStub.refused
        let coordinator = makeCoordinator(gaze: gaze)

        do {
            try await coordinator.start()
            XCTFail("start() should have thrown")
        } catch {}

        let running = await coordinator.currentSnapshot.isEngineRunning
        XCTAssertFalse(running)
    }

    func testStopIsVisibleInTheSnapshotAsSoonAsItReturns() async throws {
        let coordinator = makeCoordinator()
        try await coordinator.start()
        await coordinator.stop()
        let running = await coordinator.currentSnapshot.isEngineRunning
        XCTAssertFalse(running)
    }

    private enum GazeErrorStub: Error { case refused }
}
