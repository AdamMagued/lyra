import SwiftUI
import Combine
import LyraCore
import LyraGaze
import LyraSpeech
import LyraInput
import LyraAccessibility
import AVFoundation
import Speech
import AppKit

/// Owns the platform objects and mirrors the coordinator's state into SwiftUI.
///
/// Deliberately thin. Everything the UI shows is either a field of `LyraSnapshot` or a
/// property of the calibration run; there is no second copy of engine state to drift out
/// of sync with the coordinator. The previous version kept `isCursorActive`,
/// `calibrationAccuracy` and `meanPixelError` as separate published values updated from
/// callbacks, which is how the interface ended up able to show a stale gaze dot next to
/// a fresh selection.
@MainActor
public final class AppViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var snapshot = LyraSnapshot()
    @Published public private(set) var previewImage: CGImage?

    @Published public private(set) var calibrationStage: CalibrationStage = .idle
    @Published public private(set) var calibrationProgress: CalibrationCapture.Progress?
    @Published public private(set) var calibrationError: String?
    @Published public private(set) var calibrationResult: CalibrationResult?

    /// Where the user is in the calibration flow.
    ///
    /// Calibration used to have no first act and no last one: pressing Calibrate threw the
    /// user straight at a dot with no warning, and when the run ended the surface closed
    /// itself with the outcome reported as a line of status text on a window they were no
    /// longer looking at. Both ends of a task you cannot see the edges of read as a
    /// malfunction.
    public enum CalibrationStage: Equatable {
        case idle
        /// Explaining what is about to happen, before anything starts.
        case intro
        case running
        /// Run complete; the model is being fitted.
        case fitting
        /// Showing the outcome and how good it is.
        case finished
    }

    public struct CalibrationResult: Equatable {
        public let errorPixels: Double
        public let usedPoints: Int
        public let totalPoints: Int
        public let abandonedPoints: Int
        public let isQuick: Bool

        /// Whether the fit came out tight enough to point at things with. Roughly the
        /// height of a line of text — below this, gaze lands where the user intended; far
        /// above it, the lens is doing all the work.
        public var isPrecise: Bool { errorPixels <= 70 }
    }

    /// True while a calibration surface is up and the engine is not available to selection.
    public var isCalibrating: Bool {
        calibrationStage == .intro || calibrationStage == .running || calibrationStage == .fitting
    }

    /// Which pattern the intro screen is offering.
    @Published public private(set) var calibrationPatternName = CalibrationPattern.standard.name

    /// Roughly how long the offered run will take, in seconds.
    public var calibrationEstimateSeconds: Int {
        guard let pendingPattern else { return 0 }
        return Int(CalibrationCapture.estimatedDuration(for: pendingPattern).rounded())
    }

    /// How many targets the offered run will show.
    public var calibrationPointCount: Int { pendingPattern?.points.count ?? 0 }

    private var pendingPattern: CalibrationPattern?

    @Published public private(set) var cameraGranted = false
    @Published public private(set) var microphoneGranted = false
    @Published public private(set) var speechGranted = false
    @Published public private(set) var accessibilityGranted = false

    @Published public var showGazeOverlay = true {
        didSet { overlays.setIndicatorVisible(showGazeOverlay, viewModel: self) }
    }

    /// Whether the lens opens by itself on a cluster of small controls. Defaults on,
    /// because that is the behaviour that makes the thing usable without teaching anyone
    /// a command first — but it is the kind of help that becomes irritating when it is
    /// wrong, so it has to be one click from off.
    @Published public var autoLensEnabled = true {
        didSet { Task { await coordinator.setAutoLensEnabled(autoLensEnabled) } }
    }

    /// Whether Stage Manager's strip is on. Surfaced because "why can't I select the
    /// thumbnails" has exactly one answer when this is false.
    public var isStageManagerOn: Bool { StripScanner.isStageManagerEnabled }

    /// The map currently driving gaze. Kept here as a stored value rather than read back
    /// from the coordinator, whose state is actor-isolated and cannot be touched
    /// synchronously from a view body.
    @Published public private(set) var calibrationMap: CalibrationMap = .identity

    /// Set when a stored calibration was found but no longer applies — the display or
    /// camera changed underneath it. Surfaced rather than silently dropped, because the
    /// alternative is a user whose gaze is subtly wrong with no explanation.
    @Published public private(set) var calibrationInvalidReason: String?

    public var isCalibrated: Bool { calibrationMap.isCalibrated }

    /// Identifies the display and camera the setup currently consists of.
    ///
    /// This is what makes calibration follow the machine rather than being a one-off
    /// ritual: a map is only valid for the geometry it was measured in, and this is how
    /// that geometry is named.
    public var currentCalibrationContext: CalibrationMap.CalibrationContext {
        CalibrationMap.CalibrationContext(
            displayID: Self.mainDisplayID(),
            cameraID: gazeProvider.activeCameraID,
            screenSize: NSScreen.main.map {
                LyraSize(width: Double($0.frame.width), height: Double($0.frame.height))
            }
        )
    }

    /// `CGDirectDisplayID` of the screen Lyra is operating on.
    static func mainDisplayID() -> UInt32? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    // MARK: - Dependencies

    public let gazeProvider: VisionGazeProvider
    public let speechProvider: NativeSpeechProvider
    public let inputController: CGInputController
    public let targetProvider: MacTargetProvider
    public let coordinator: LyraCoordinator

    private let overlays = OverlayWindowManager.shared
    private let calibrationStorageKey = "com.lyra.calibrationMap"
    private var capture: CalibrationCapture?
    private var snapshotTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?

    private static let patterns: [CalibrationPattern] = [.standard, .quick]

    public init() {
        let gaze = VisionGazeProvider()
        let speech = NativeSpeechProvider()
        let input = CGInputController()
        let targets = MacTargetProvider()

        self.gazeProvider = gaze
        self.speechProvider = speech
        self.inputController = input
        self.targetProvider = targets
        self.coordinator = LyraCoordinator(
            gazeProvider: gaze,
            speechProvider: speech,
            targetProvider: targets,
            inputController: input
        )

        updateScreenSize()
        refreshPermissions()
        observeCoordinator()
        observeDisplayChanges()

        gazeProvider.onPreviewFrame = { [weak self] image in
            Task { @MainActor [weak self] in self?.previewImage = image }
        }

        Task { await restoreCalibration() }
    }

    // MARK: - Display changes

    /// Re-reads the screen and re-checks the calibration whenever the display setup moves.
    ///
    /// Resolution changes, a display being attached, the arrangement changing — all of
    /// them invalidate assumptions Lyra is holding: the screen size every gaze point is
    /// scaled by, and the validity of a map fitted under different geometry. Nothing
    /// announces this, so it has to be watched for.
    private func observeDisplayChanges() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDisplayChange() }
        }
    }

    private func handleDisplayChange() {
        updateScreenSize()
        revalidateCalibration()
    }

    /// Drops the stored calibration if the setup it was fitted in is gone.
    ///
    /// Called on a display change and again once the camera has started, because which
    /// camera is in use is only knowable after that — a calibration made through an
    /// external webcam is meaningless once the machine is running on its built-in one.
    func revalidateCalibration() {
        guard calibrationMap.isCalibrated else { return }
        let context = currentCalibrationContext
        guard !calibrationMap.isUsable(with: context) else {
            calibrationInvalidReason = nil
            return
        }

        let changed = calibrationMap.context?.difference(from: context) ?? "a change in your setup"
        calibrationInvalidReason = "Your display setup changed (\(changed)), so the saved calibration no longer applies. Calibrate again."
        resetCalibration()
    }

    // MARK: - Coordinator observation

    private func observeCoordinator() {
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await update in await self.coordinator.snapshots {
                guard !Task.isCancelled else { break }
                self.snapshot = update
            }
        }
    }

    public func updateScreenSize() {
        guard let screen = NSScreen.main else { return }
        let size = LyraSize(
            width: Double(screen.frame.width),
            height: Double(screen.frame.height)
        )
        targetProvider.setScreenSize(size)
        Task { await coordinator.setScreenSize(size) }
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityGranted = AccessibilityHelper.isAccessibilityTrusted
    }

    public func requestPermissions() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if !AccessibilityHelper.isAccessibilityTrusted {
                _ = AccessibilityHelper.requestAccessibilityPrompt()
            }
            refreshPermissions()
        }
    }

    // MARK: - Engine

    public func start() async {
        updateScreenSize()
        do {
            try await coordinator.start()
            // Only now is it known which camera is actually running, so this is the first
            // moment a stored calibration can be checked against it.
            revalidateCalibration()
            if showGazeOverlay {
                overlays.setIndicatorVisible(true, viewModel: self)
            }
        } catch {
            refreshPermissions()
        }
    }

    public func stop() async {
        await coordinator.stop()
        previewImage = nil
        overlays.setIndicatorVisible(false, viewModel: self)
    }

    public func toggleEngine() {
        Task {
            if snapshot.isEngineRunning { await stop() } else { await start() }
        }
    }

    // MARK: - Commands

    public func send(_ command: LyraCommand) {
        Task { await coordinator.submit(command: command) }
    }

    // MARK: - Calibration

    /// Opens the calibration surface on its explanation screen. Nothing is measured yet.
    public func startCalibration(quick: Bool = false) {
        pendingPattern = quick ? CalibrationPattern.quick : CalibrationPattern.standard
        calibrationPatternName = pendingPattern?.name ?? CalibrationPattern.standard.name
        calibrationError = nil
        calibrationProgress = nil
        calibrationResult = nil
        calibrationStage = .intro
        overlays.showCalibrationWindow(viewModel: self)
    }

    /// Begins measuring, once the user has read what is about to happen and is ready.
    ///
    /// Split from `startCalibration` because the run needs the user settled and looking at
    /// the screen. Starting the instant the button is pressed means the first points are
    /// measured while they are still reading the button they just clicked.
    public func beginCalibration() {
        guard calibrationStage == .intro, let pattern = pendingPattern else { return }
        let run = CalibrationCapture(pattern: pattern)
        capture = run
        calibrationStage = .running

        // Built outside the task below so the observer holds `self` weakly without
        // fighting the strong capture the surrounding task already has. The coordinator
        // is owned by this view model, so a strong self here would be a genuine cycle
        // for as long as the observer is installed.
        let observer: @Sendable (GazeFeatures) -> Void = { [weak self] features in
            // Timestamped here, on the capture thread, not after the hop to the main
            // actor: the state machine's settle and hold timings have to reflect when the
            // frame was actually measured, not when the UI got round to it.
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in self?.ingest(features, at: now) }
        }

        Task {
            await start()

            // Asked of the coordinator, not read from `snapshot`.
            //
            // `snapshot` is a mirror fed by an async task consuming the coordinator's
            // stream, and it has not necessarily caught up by the time `start()` returns —
            // so on the first calibration after launch, which is exactly when the engine
            // is not running yet, this guard read a stale `false` and cancelled the run
            // it had just started. The user saw the overlay flash and vanish.
            guard await coordinator.currentSnapshot.isEngineRunning else {
                calibrationError = "The camera did not start, so calibration cannot run. Check Camera permission, then try again."
                closeCalibration()
                return
            }

            // Selection is meaningless while the user is being asked to look at dots,
            // and a stray voice command mid-run would move the cursor under them.
            await coordinator.submit(command: .stopTracking)
            await coordinator.setFeatureObserver(observer)
            run.start(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func ingest(_ features: GazeFeatures, at time: TimeInterval) {
        guard isCalibrating, let capture else { return }

        guard let progress = capture.update(features: features, at: time) else { return }
        calibrationProgress = progress

        if progress.isFinished {
            completeCalibration(with: capture)
        }
    }

    /// Marks the current point as bad and makes the run go back to it.
    public func retryCurrentPoint() {
        guard isCalibrating, let capture else { return }
        capture.flagCurrentPointForRetry(at: ProcessInfo.processInfo.systemUptime)
    }

    private func completeCalibration(with capture: CalibrationCapture) {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        // Captured before the fit rather than after, and before the await below: this is
        // the setup the samples were actually taken in, and `activeCameraID` is only
        // populated once the camera has started.
        let context = currentCalibrationContext

        Task {
            calibrationStage = .fitting
            await coordinator.setFeatureObserver(nil)

            let isQuick = pendingPattern?.name == CalibrationPattern.quick.name

            do {
                let map = try GazeCalibrator().calibrate(
                    samples: capture.samples,
                    screenWidth: Double(size.width),
                    screenHeight: Double(size.height),
                    context: context
                )
                await coordinator.setCalibrationMap(map)
                calibrationMap = map
                calibrationInvalidReason = nil
                persist(map)
                calibrationError = nil

                // A run that dropped points still fits a map, just from less data than
                // the user thinks they gave it. The result screen says so, because that
                // is the difference between "the calibration is bad" and knowing which
                // run to repeat.
                calibrationResult = CalibrationResult(
                    errorPixels: map.validationErrorPixels,
                    usedPoints: map.pointCount,
                    totalPoints: capture.totalPoints,
                    abandonedPoints: capture.abandonedPoints.count,
                    isQuick: isQuick
                )
            } catch {
                calibrationError = error.localizedDescription
            }

            self.capture = nil
            calibrationStage = .finished
            refreshPermissions()
        }
    }

    /// Abandons a run in progress, or closes the result screen.
    public func cancelCalibration() {
        closeCalibration()
    }

    /// Dismisses the calibration surface and returns the engine to normal use.
    public func closeCalibration() {
        calibrationStage = .idle
        capture = nil
        calibrationProgress = nil
        pendingPattern = nil
        overlays.closeCalibrationWindow()
        Task { await coordinator.setFeatureObserver(nil) }
    }

    /// Runs another calibration immediately, using the same pattern.
    public func repeatCalibration() {
        let quick = pendingPattern?.name == CalibrationPattern.quick.name
        closeCalibration()
        startCalibration(quick: quick)
    }

    public func resetCalibration() {
        UserDefaults.standard.removeObject(forKey: calibrationStorageKey)
        calibrationMap = .identity
        Task { await coordinator.setCalibrationMap(.identity) }
    }

    private func persist(_ map: CalibrationMap) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: calibrationStorageKey)
    }

    private func restoreCalibration() async {
        guard let data = UserDefaults.standard.data(forKey: calibrationStorageKey),
              let map = try? JSONDecoder().decode(CalibrationMap.self, from: data),
              map.schemaVersion == GazeFeatures.schemaVersion else {
            return
        }

        // The camera is only known once it is running, and the display only matters when
        // a map was fitted against another one, so the check is redone at start rather
        // than trusted from launch.
        let context = currentCalibrationContext
        guard map.isUsable(with: context) else {
            let changed = map.context?.difference(from: context) ?? "a change in your setup"
            calibrationInvalidReason = "Your display setup changed (\(changed)), so the saved calibration no longer applies. Calibrate again."
            resetCalibration()
            return
        }

        await coordinator.setCalibrationMap(map)
        calibrationMap = map
    }
}
