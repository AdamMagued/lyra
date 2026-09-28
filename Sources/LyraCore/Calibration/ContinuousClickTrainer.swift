import Foundation

/// Passive continuous click trainer.
///
/// Implements WebGazer's continuous online calibration:
/// When active, whenever a user clicks during normal computer usage (or activates a target),
/// the click coordinates serve as self-supervised ground truth for the user's current gaze.
/// The buffered facial landmarks are paired with the click location and added to the
/// calibration dataset, periodically or incrementally updating the Ridge Regression model.
public final class ContinuousClickTrainer: @unchecked Sendable {

    private let maxPassiveSamples: Int
    private let minimumFrames: Int
    private let frameBufferLimit: Int

    public var isEnabled: Bool = true
    public private(set) var baseSamples: [CalibrationSample] = []
    public private(set) var passiveSamples: [CalibrationSample] = []
    public private(set) var lastUpdatedMap: CalibrationMap?

    private var frames: [GazeFeatures] = []
    private let lock = NSLock()

    public init(
        maxPassiveSamples: Int = 50,
        minimumFrames: Int = 3,
        frameBufferLimit: Int = 20
    ) {
        self.maxPassiveSamples = maxPassiveSamples
        self.minimumFrames = max(minimumFrames, 2)
        self.frameBufferLimit = max(frameBufferLimit, minimumFrames)
    }

    /// Sets the initial base samples from a full calibration session (e.g. 45 WebGazer samples).
    public func setBaseSamples(_ samples: [CalibrationSample]) {
        lock.lock()
        defer { lock.unlock() }
        self.baseSamples = samples
    }

    /// Buffers incoming eye/face features.
    public func observe(features: GazeFeatures) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return }
        frames.append(features)
        if frames.count > frameBufferLimit {
            frames.removeFirst()
        }
    }

    /// Registers a passive click during normal computer usage.
    ///
    /// If the click has a reliable eye observation, aggregates the sample,
    /// adds it to the sliding window, and refits the calibration map with Ridge Regression.
    ///
    /// - Parameters:
    ///   - normalizedLocation: Click coordinate in 0...1 normalised screen space.
    ///   - screenSize: Current screen resolution.
    ///   - context: Screen/camera context.
    /// - Returns: Newly updated `CalibrationMap` if refitting succeeded, or `nil`.
    @discardableResult
    public func registerClick(
        atNormalized normalizedLocation: (x: Double, y: Double),
        screenSize: LyraSize,
        context: CalibrationMap.CalibrationContext? = nil
    ) -> CalibrationMap? {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return nil }

        // Ensure location is on-screen
        guard normalizedLocation.x >= 0.0, normalizedLocation.x <= 1.0,
              normalizedLocation.y >= 0.0, normalizedLocation.y <= 1.0 else {
            return nil
        }

        // Aggregate recent frames
        guard let sample = CalibrationSample.aggregate(
            frames: frames,
            targetX: normalizedLocation.x,
            targetY: normalizedLocation.y,
            minimumFrames: minimumFrames
        ) else {
            return nil
        }

        passiveSamples.append(sample)
        if passiveSamples.count > maxPassiveSamples {
            passiveSamples.removeFirst()
        }

        // Combine base samples + passive samples for fitting
        let allSamples = baseSamples + passiveSamples
        guard allSamples.count >= 9 else { return nil }

        let calibrator = GazeCalibrator(lambda: 1.0, minimumSamples: 9)
        guard let newMap = try? calibrator.calibrate(
            samples: allSamples,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height,
            context: context
        ) else {
            // Rollback the uncalibratable sample to avoid corrupting future attempts
            passiveSamples.removeLast()
            return nil
        }

        // Guard against massive regression: if error grew by more than 35% compared to existing map, discard
        if let previous = lastUpdatedMap, previous.validationErrorPixels.isFinite {
            if newMap.validationErrorPixels > previous.validationErrorPixels * 1.35 {
                passiveSamples.removeLast()
                return nil
            }
        }

        self.lastUpdatedMap = newMap
        return newMap
    }

    /// Clears passive samples.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        passiveSamples.removeAll()
        frames.removeAll()
        lastUpdatedMap = nil
    }
}
