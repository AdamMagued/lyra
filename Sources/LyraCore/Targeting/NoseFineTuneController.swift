import Foundation
import CoreGraphics

/// Hybrid Gaze + Nose Precision Steering Controller.
///
/// Supports three tracking modes:
/// 1. **Nose Only** (`.noseOnly`): Pure head/nose pointer. Point your nose to move
///    the cursor anywhere across the screen. Zero eye-gaze jitter, zero calibration needed.
///    Employs an adaptive 1-Euro filter and fixation deadband for silky smooth, rock-solid stability.
/// 2. **Hybrid** (`.hybrid`): Fast eye saccades snap coarse intent to screen regions;
///    subtle nose nudging fine-tunes cursor placement with sub-pixel precision.
/// 3. **Gaze Only** (`.gazeOnly`): Traditional eye-gaze tracking only.
public final class NoseFineTuneController: @unchecked Sendable {

    public enum Mode: String, CaseIterable, Codable, Sendable {
        case noseOnly = "Nose Only"
        case hybrid = "Hybrid"
        case gazeOnly = "Gaze Only"
    }

    private let lock = NSLock()

    public var mode: Mode
    public var isEnabled: Bool
    public var sensitivity: Double // Gain multiplier (default: 2.0)
    public var saccadeThreshold: Double // Normalized distance for eye jump in hybrid mode (default: 0.07 ≈ 100 px)
    public var deadband: Double // Angular deadband in rigid skull deflection space (default: 0.009)
    public var speedThreshold: Double // Speed below which head is considered stationary (default: 0.015)
    public var dwellFramesToLock: Int // Stationary frames before engaging hard fixation lock (default: 4 ≈ 130ms)
    public var invertX: Bool // Horizontal inversion toggle (default: false)
    public var invertY: Bool // Vertical inversion toggle (default: false)

    // MARK: - Nose Only State
    private var neutralYaw: Double?
    private var neutralPitch: Double?
    private var anchorYaw: Double = 0.0
    private var anchorPitch: Double = 0.0
    private var isLocked: Bool = true
    private var lockedScreenPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var filteredScreenPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var stationaryFrames: Int = 0
    private var prevYaw: Double?
    private var prevPitch: Double?
    private var prevTime: Date?
    private let noseFilter: OneEuroFilter
    private var lastNosePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // MARK: - Hybrid State
    private var anchorPoint: CGPoint?
    private var referenceYaw: Double = 0.0
    private var referencePitch: Double = 0.0
    private var currentFilteredOffset: CGPoint = .zero
    private var lastUpdateTime: Date = Date()

    public init(
        mode: Mode = .noseOnly,
        isEnabled: Bool = true,
        sensitivity: Double = 2.0,
        saccadeThreshold: Double = 0.07,
        deadband: Double = 0.009,
        speedThreshold: Double = 0.015,
        dwellFramesToLock: Int = 4,
        invertX: Bool = false,
        invertY: Bool = false
    ) {
        self.mode = mode
        self.isEnabled = isEnabled
        self.sensitivity = sensitivity
        self.saccadeThreshold = saccadeThreshold
        self.deadband = deadband
        self.speedThreshold = speedThreshold
        self.dwellFramesToLock = dwellFramesToLock
        self.invertX = invertX
        self.invertY = invertY
        self.noseFilter = OneEuroFilter(
            minCutoff: 1.0,
            beta: 0.03,
            dCutoff: 1.0,
            deadbandRadius: 0.0
        )
    }

    public convenience init(
        mode: Mode = .noseOnly,
        isEnabled: Bool = true,
        sensitivity: Double = 2.0,
        saccadeThreshold: Double = 0.07,
        deadband: Double = 0.009
    ) {
        self.init(
            mode: mode,
            isEnabled: isEnabled,
            sensitivity: sensitivity,
            saccadeThreshold: saccadeThreshold,
            deadband: deadband,
            speedThreshold: 0.015,
            dwellFramesToLock: 4,
            invertX: false,
            invertY: false
        )
    }

    /// Resets neutral pose and internal filters.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        neutralYaw = nil
        neutralPitch = nil
        anchorYaw = 0.0
        anchorPitch = 0.0
        isLocked = true
        lockedScreenPoint = CGPoint(x: 0.5, y: 0.5)
        filteredScreenPoint = CGPoint(x: 0.5, y: 0.5)
        lastNosePoint = CGPoint(x: 0.5, y: 0.5)
        stationaryFrames = 0
        prevYaw = nil
        prevPitch = nil
        prevTime = nil
        anchorPoint = nil
        referenceYaw = 0.0
        referencePitch = 0.0
        currentFilteredOffset = .zero
        noseFilter.reset()
    }

    /// Recenters the nose pointer to the current head orientation.
    /// The next incoming frame will establish the new neutral head pose at screen center (0.5, 0.5).
    public func recenter() {
        lock.lock()
        defer { lock.unlock() }
        neutralYaw = nil
        neutralPitch = nil
        anchorYaw = 0.0
        anchorPitch = 0.0
        isLocked = true
        lockedScreenPoint = CGPoint(x: 0.5, y: 0.5)
        filteredScreenPoint = CGPoint(x: 0.5, y: 0.5)
        lastNosePoint = CGPoint(x: 0.5, y: 0.5)
        stationaryFrames = 0
        prevYaw = nil
        prevPitch = nil
        prevTime = nil
        anchorPoint = nil
        referenceYaw = 0.0
        referencePitch = 0.0
        currentFilteredOffset = .zero
        noseFilter.reset()
    }

    /// Sets the configuration parameters.
    public func configure(
        mode: Mode? = nil,
        isEnabled: Bool? = nil,
        sensitivity: Double? = nil,
        invertX: Bool? = nil,
        invertY: Bool? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let mode { self.mode = mode }
        if let isEnabled { self.isEnabled = isEnabled }
        if let sensitivity { self.sensitivity = max(0.2, min(5.0, sensitivity)) }
        if let invertX { self.invertX = invertX }
        if let invertY { self.invertY = invertY }
    }

    /// Uniform update method taking a platform-neutral LyraPoint.
    public func update(
        rawGaze: LyraPoint,
        yaw: Double,
        pitch: Double,
        now: Date = Date()
    ) -> LyraPoint {
        let cgResult = update(rawGaze: CGPoint(x: rawGaze.x, y: rawGaze.y), yaw: yaw, pitch: pitch, now: now)
        return LyraPoint(x: Double(cgResult.x), y: Double(cgResult.y))
    }

    /// Uniform update method that dispatches based on the current mode.
    public func update(
        rawGaze: CGPoint,
        yaw: Double,
        pitch: Double,
        now: Date = Date()
    ) -> CGPoint {
        lock.lock()
        defer { lock.unlock() }

        guard isEnabled else { return rawGaze }

        switch mode {
        case .noseOnly:
            return updateNoseOnlyInternal(yaw: yaw, pitch: pitch, now: now)
        case .hybrid:
            return updateHybridInternal(rawGaze: rawGaze, yaw: yaw, pitch: pitch, now: now)
        case .gazeOnly:
            return rawGaze
        }
    }

    /// Dedicated pure nose steering update.
    /// Can be called directly even when no calibration map or eye gaze is present.
    public func updateNoseOnly(
        yaw: Double,
        pitch: Double,
        now: Date = Date()
    ) -> CGPoint {
        lock.lock()
        defer { lock.unlock() }
        return updateNoseOnlyInternal(yaw: yaw, pitch: pitch, now: now)
    }

    // MARK: - Private Implementations

    private func updateNoseOnlyInternal(
        yaw: Double,
        pitch: Double,
        now: Date
    ) -> CGPoint {
        guard let ny = neutralYaw, let np = neutralPitch else {
            neutralYaw = yaw
            neutralPitch = pitch
            anchorYaw = yaw
            anchorPitch = pitch
            isLocked = true
            lockedScreenPoint = CGPoint(x: 0.5, y: 0.5)
            filteredScreenPoint = CGPoint(x: 0.5, y: 0.5)
            lastNosePoint = CGPoint(x: 0.5, y: 0.5)
            stationaryFrames = 0
            prevYaw = yaw
            prevPitch = pitch
            prevTime = now
            noseFilter.reset()
            _ = noseFilter.filter(GazePoint(x: 0.5, y: 0.5, confidence: 1.0, timestamp: now))
            return lastNosePoint
        }

        let dt = max(now.timeIntervalSince(prevTime ?? now), 0.001)
        let distFromAnchor = hypot(yaw - anchorYaw, pitch - anchorPitch)
        let speed = hypot(yaw - (prevYaw ?? yaw), pitch - (prevPitch ?? pitch)) / dt
        prevYaw = yaw
        prevPitch = pitch
        prevTime = now

        if isLocked {
            if distFromAnchor <= deadband {
                return lockedScreenPoint
            } else {
                // Break out of resting lock into intentional head steering
                isLocked = false
                stationaryFrames = 0
            }
        } else {
            if speed < speedThreshold {
                stationaryFrames += 1
                if stationaryFrames >= dwellFramesToLock {
                    // Head came to rest at target: engage hard fixation lock
                    isLocked = true
                    anchorYaw = yaw
                    anchorPitch = pitch
                    lockedScreenPoint = filteredScreenPoint
                    lastNosePoint = lockedScreenPoint
                    return lockedScreenPoint
                }
            } else {
                stationaryFrames = 0
            }
        }

        // Direction signs: natural motion maps head turn right -> cursor right, tilt up -> cursor up
        let signX = invertX ? -1.0 : 1.0
        let signY = invertY ? -1.0 : 1.0

        let deltaAnchorYaw = (yaw - anchorYaw) * signX
        let deltaAnchorPitch = -(pitch - anchorPitch) * signY
        let r = hypot(deltaAnchorYaw, deltaAnchorPitch)

        let effDeltaYaw: Double
        let effDeltaPitch: Double
        if r > deadband {
            let factor = 1.0 - (deadband / r)
            effDeltaYaw = deltaAnchorYaw * factor
            effDeltaPitch = deltaAnchorPitch * factor
        } else {
            effDeltaYaw = 0.0
            effDeltaPitch = 0.0
        }

        let effYaw = (anchorYaw - ny) * signX + effDeltaYaw
        let effPitch = -(anchorPitch - np) * signY + effDeltaPitch

        let gainX = 4.5 * sensitivity
        let gainY = 6.0 * sensitivity

        let rawTargetX = 0.5 + effYaw * gainX
        let rawTargetY = 0.5 + effPitch * gainY

        let clampedX = min(max(rawTargetX, 0.005), 0.995)
        let clampedY = min(max(rawTargetY, 0.005), 0.995)

        let filtered = noseFilter.filter(
            GazePoint(x: clampedX, y: clampedY, confidence: 1.0, timestamp: now)
        )

        let result = CGPoint(x: filtered.x, y: filtered.y)
        filteredScreenPoint = result
        lastNosePoint = result
        return result
    }

    private func updateHybridInternal(
        rawGaze: CGPoint,
        yaw: Double,
        pitch: Double,
        now: Date
    ) -> CGPoint {
        guard let currentAnchor = anchorPoint else {
            anchorPoint = rawGaze
            referenceYaw = yaw
            referencePitch = pitch
            currentFilteredOffset = .zero
            lastUpdateTime = now
            return rawGaze
        }

        let gazeJumpDist = hypot(rawGaze.x - currentAnchor.x, rawGaze.y - currentAnchor.y)

        // Saccade / Large eye jump detected: relocate anchor to the new gaze target
        if gazeJumpDist > saccadeThreshold {
            anchorPoint = rawGaze
            referenceYaw = yaw
            referencePitch = pitch
            currentFilteredOffset = .zero
            lastUpdateTime = now
            return rawGaze
        }

        // Slow drift tracking: allow anchor to gently follow sustained eye movement
        let followAlpha = 0.04
        let updatedAnchorX = currentAnchor.x + (rawGaze.x - currentAnchor.x) * followAlpha
        let updatedAnchorY = currentAnchor.y + (rawGaze.y - currentAnchor.y) * followAlpha
        anchorPoint = CGPoint(x: updatedAnchorX, y: updatedAnchorY)

        // Compute head/nose delta from the reference anchor pose
        let signX = invertX ? -1.0 : 1.0
        let signY = invertY ? -1.0 : 1.0
        let dYaw = (yaw - referenceYaw) * signX
        let dPitch = -(pitch - referencePitch) * signY

        let dist = hypot(dYaw, dPitch)
        let effDYaw: Double
        let effDPitch: Double
        if dist > deadband {
            let factor = 1.0 - (deadband / dist)
            effDYaw = dYaw * factor
            effDPitch = dPitch * factor
        } else {
            effDYaw = 0.0
            effDPitch = 0.0
        }

        let targetOffsetX = effDYaw * sensitivity
        let targetOffsetY = effDPitch * sensitivity

        let dt = min(max(now.timeIntervalSince(lastUpdateTime), 0.005), 0.1)
        lastUpdateTime = now
        let filterAlpha = min(1.0, max(0.1, dt * 20.0))

        let newOffsetX = currentFilteredOffset.x + (targetOffsetX - currentFilteredOffset.x) * filterAlpha
        let newOffsetY = currentFilteredOffset.y + (targetOffsetY - currentFilteredOffset.y) * filterAlpha
        currentFilteredOffset = CGPoint(x: newOffsetX, y: newOffsetY)

        // Extended reach: smoothly drag anchor along if user steers past local radius
        let maxLocalRadius = 0.18
        if abs(newOffsetX) > maxLocalRadius {
            let excess = newOffsetX - copysign(maxLocalRadius, newOffsetX)
            anchorPoint = CGPoint(x: anchorPoint!.x + excess * 0.25, y: anchorPoint!.y)
        }
        if abs(newOffsetY) > maxLocalRadius {
            let excess = newOffsetY - copysign(maxLocalRadius, newOffsetY)
            anchorPoint = CGPoint(x: anchorPoint!.x, y: anchorPoint!.y + excess * 0.25)
        }

        let finalX = min(max(anchorPoint!.x + newOffsetX, 0.0), 1.0)
        let finalY = min(max(anchorPoint!.y + newOffsetY, 0.0), 1.0)

        return CGPoint(x: finalX, y: finalY)
    }
}
