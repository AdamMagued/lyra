import Foundation

/// Smooth pursuit calibration driven by continuous visual tracking.
///
/// Unlike click-based calibration, which requires 64 physical clicks and is confounded
/// by hand-movement saccades and click-time head jerks, smooth pursuit relies on the
/// involuntary ocular motor pursuit reflex: the human eye smoothly locks onto a visual
/// target gliding at 8–15°/sec across the screen.
///
/// In 18 seconds at camera rate (30 fps), this acquires ~500 ground-truth gaze pairs
/// with zero manual clicks. The samples are spatially binned across a 5x5 grid with
/// median outlier rejection, yielding 25 clean, uniformly distributed `CalibrationSample`s
/// for `GazeCalibrator`.
///
/// Pure domain logic and hardware-free, making it fully unit-testable without camera or display.
public final class PursuitCalibration: @unchecked Sendable {

    public enum Phase: String, Sendable, Codable {
        case countdown
        case pursuing
        case finished
    }

    /// Progress information surfaced to the UI.
    public struct Progress: Sendable, Equatable {
        public let phase: Phase
        public let countdownRemaining: Double
        public let progress: Double
        /// Normalized screen position of the moving dot, origin top-left.
        public let pointX: Double
        public let pointY: Double
        public let framesCaptured: Int
        public let elapsedSeconds: Double
        public let durationSeconds: Double
        public let isFinished: Bool

        public init(
            phase: Phase,
            countdownRemaining: Double,
            progress: Double,
            pointX: Double,
            pointY: Double,
            framesCaptured: Int,
            elapsedSeconds: Double,
            durationSeconds: Double,
            isFinished: Bool
        ) {
            self.phase = phase
            self.countdownRemaining = countdownRemaining
            self.progress = progress
            self.pointX = pointX
            self.pointY = pointY
            self.framesCaptured = framesCaptured
            self.elapsedSeconds = elapsedSeconds
            self.durationSeconds = durationSeconds
            self.isFinished = isFinished
        }
    }

    public let durationSeconds: Double
    public let countdownSeconds: Double
    public let latencyCompensation: Double

    private var startTime: Date?
    private var isCompleted = false

    public struct Observation: Sendable {
        public let targetX: Double
        public let targetY: Double
        public let features: GazeFeatures
        public let timestamp: Date
    }

    private var observations: [Observation] = []
    private let lock = NSLock()

    /// Waypoints forming a continuous boustrophedon sweep through all 5 screen rows.
    ///
    /// Starts at screen center (0.5, 0.5), glides to the top row, zigzags down through
    /// all 5 rows covering extreme edges and center evenly, then returns smoothly to center.
    public static let waypoints: [(x: Double, y: Double)] = [
        (0.50, 0.50),   // 0: start center
        (0.254, 0.254), // 1: ease toward top-left
        (0.008, 0.008), // 2: row 0 left (extreme top-left)
        (0.254, 0.008), // 3
        (0.500, 0.008), // 4: row 0 mid (extreme top)
        (0.746, 0.008), // 5
        (0.992, 0.008), // 6: row 0 right (extreme top-right)
        (0.992, 0.131), // 7: round turn down
        (0.992, 0.254), // 8: row 1 right
        (0.746, 0.254), // 9
        (0.500, 0.254), // 10: row 1 mid
        (0.254, 0.254), // 11
        (0.008, 0.254), // 12: row 1 left
        (0.008, 0.377), // 13: round turn down
        (0.008, 0.500), // 14: row 2 left
        (0.254, 0.500), // 15
        (0.500, 0.500), // 16: row 2 center
        (0.746, 0.500), // 17
        (0.992, 0.500), // 18: row 2 right
        (0.992, 0.623), // 19: round turn down
        (0.992, 0.746), // 20: row 3 right
        (0.746, 0.746), // 21
        (0.500, 0.746), // 22: row 3 mid
        (0.254, 0.746), // 23
        (0.008, 0.746), // 24: row 3 left
        (0.008, 0.869), // 25: round turn down
        (0.008, 0.992), // 26: row 4 left (extreme bottom-left)
        (0.254, 0.992), // 27
        (0.500, 0.992), // 28: row 4 mid (extreme bottom)
        (0.746, 0.992), // 29
        (0.992, 0.992), // 30: row 4 right (extreme bottom-right)
        (0.746, 0.746), // 31: return curve
        (0.500, 0.500)  // 32: stop center
    ]

    public init(
        durationSeconds: Double = 28.0,
        countdownSeconds: Double = 2.0,
        latencyCompensation: Double = 0.0
    ) {
        self.durationSeconds = max(durationSeconds, 5.0)
        self.countdownSeconds = max(countdownSeconds, 0.0)
        self.latencyCompensation = max(latencyCompensation, 0.0)
    }

    public func start(at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        startTime = date
        observations.removeAll()
        isCompleted = false
    }

    /// Evaluates the target position on the trajectory at a given normalized progress in [0, 1].
    public static func pointOnTrajectory(progress: Double) -> (x: Double, y: Double) {
        let clamped = max(0.0, min(1.0, progress))
        // Quintic smootherstep time-warp: zero velocity and acceleration at start & end.
        let u = clamped * clamped * clamped * (clamped * (clamped * 6.0 - 15.0) + 10.0)

        let pts = waypoints
        let nSegments = pts.count - 1
        let s = u * Double(nSegments)
        let seg = min(Int(s), nSegments - 1)
        let localT = s - Double(seg)

        // Padded Catmull-Rom endpoints
        let p0 = seg > 0 ? pts[seg - 1] : pts[0]
        let p1 = pts[seg]
        let p2 = pts[seg + 1]
        let p3 = (seg + 2 < pts.count) ? pts[seg + 2] : pts[pts.count - 1]

        let t2 = localT * localT
        let t3 = t2 * localT

        let x = 0.5 * (
            (2.0 * p1.x) +
            (-p0.x + p2.x) * localT +
            (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2 +
            (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3
        )

        let y = 0.5 * (
            (2.0 * p1.y) +
            (-p0.y + p2.y) * localT +
            (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2 +
            (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3
        )

        return (min(max(x, 0.008), 0.992), min(max(y, 0.008), 0.992))
    }

    /// Returns the target position for the given timestamp.
    public func targetPosition(at date: Date = Date()) -> (x: Double, y: Double) {
        guard let start = startTime else { return (0.5, 0.5) }
        let elapsed = date.timeIntervalSince(start)
        if elapsed < countdownSeconds {
            return (0.5, 0.5)
        }
        let pursuitElapsed = elapsed - countdownSeconds
        let u = min(max(pursuitElapsed / durationSeconds, 0.0), 1.0)
        return Self.pointOnTrajectory(progress: u)
    }

    /// Ingests one camera frame during pursuit.
    public func observe(features: GazeFeatures, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        guard let start = startTime, !isCompleted else { return }
        let elapsed = date.timeIntervalSince(start)

        // Ignore frames during countdown fixation window
        guard elapsed >= countdownSeconds else { return }

        let pursuitElapsed = elapsed - countdownSeconds
        if pursuitElapsed >= durationSeconds {
            isCompleted = true
            return
        }

        // Account for ocular pursuit latency + camera pipeline latency:
        // The eye's gaze at `date` was aimed at the target's position earlier in time.
        let effectiveElapsed = max(0.0, pursuitElapsed - latencyCompensation)
        let u = min(max(effectiveElapsed / durationSeconds, 0.0), 1.0)
        let pos = Self.pointOnTrajectory(progress: u)

        observations.append(Observation(
            targetX: pos.x,
            targetY: pos.y,
            features: features,
            timestamp: date
        ))
    }

    /// Current progress snapshot.
    public func progress(at date: Date = Date()) -> Progress {
        lock.lock()
        defer { lock.unlock() }

        guard let start = startTime else {
            return Progress(
                phase: .countdown,
                countdownRemaining: countdownSeconds,
                progress: 0.0,
                pointX: 0.5,
                pointY: 0.5,
                framesCaptured: 0,
                elapsedSeconds: 0.0,
                durationSeconds: durationSeconds,
                isFinished: false
            )
        }

        let elapsed = date.timeIntervalSince(start)
        if elapsed < countdownSeconds {
            return Progress(
                phase: .countdown,
                countdownRemaining: max(0.0, countdownSeconds - elapsed),
                progress: 0.0,
                pointX: 0.5,
                pointY: 0.5,
                framesCaptured: 0,
                elapsedSeconds: elapsed,
                durationSeconds: durationSeconds,
                isFinished: false
            )
        }

        let pursuitElapsed = elapsed - countdownSeconds
        let u = min(max(pursuitElapsed / durationSeconds, 0.0), 1.0)
        let pos = Self.pointOnTrajectory(progress: u)
        let finished = pursuitElapsed >= durationSeconds || isCompleted

        return Progress(
            phase: finished ? .finished : .pursuing,
            countdownRemaining: 0.0,
            progress: u,
            pointX: pos.x,
            pointY: pos.y,
            framesCaptured: observations.count,
            elapsedSeconds: pursuitElapsed,
            durationSeconds: durationSeconds,
            isFinished: finished
        )
    }

    /// Aggregates continuous pursuit frames into spatially binned `CalibrationSample`s.
    ///
    /// The screen is partitioned into a 5x5 grid. For each cell with sufficient usable
    /// frames, `CalibrationSample.aggregate` filters out blinks/outliers via MAD and
    /// yields a representative sample with its true mean target position.
    public func finish(gridSize: Int = 5, minimumFramesPerBin: Int = 3) -> [CalibrationSample] {
        lock.lock()
        defer { lock.unlock() }
        isCompleted = true

        let g = max(gridSize, 3)
        var bins: [[Observation]] = Array(repeating: [], count: g * g)

        for obs in observations {
            let col = min(max(Int(obs.targetX * Double(g)), 0), g - 1)
            let row = min(max(Int(obs.targetY * Double(g)), 0), g - 1)
            bins[row * g + col].append(obs)
        }

        var samples: [CalibrationSample] = []
        for bin in bins where bin.count >= minimumFramesPerBin {
            let meanTargetX = bin.map(\.targetX).reduce(0, +) / Double(bin.count)
            let meanTargetY = bin.map(\.targetY).reduce(0, +) / Double(bin.count)
            let features = bin.map(\.features)

            if let sample = CalibrationSample.aggregate(
                frames: features,
                targetX: meanTargetX,
                targetY: meanTargetY,
                minimumFrames: minimumFramesPerBin
            ) {
                samples.append(sample)
            }
        }

        return samples
    }
}
