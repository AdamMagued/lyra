import Foundation

/// 1-Euro Filter: Gold-standard adaptive low-pass filter for human-computer interaction.
/// Dynamically adjusts cutoff frequency based on movement velocity:
/// - Low speed (fixation): Low cutoff frequency -> Heavy filtering, zero jitter.
/// - High speed (saccade): High cutoff frequency -> Instant responsiveness, zero lag.
/// Reference: Casiez, Roussel, Vogel (CHI 2012)
public final class OneEuroFilter: @unchecked Sendable {
    private let lock = NSLock()
    
    // Configurable parameters
    public var minCutoff: Double      // Minimum cutoff frequency in Hz for slow movement (e.g. 0.8 Hz)
    public var beta: Double           // Speed coefficient for adapting cutoff (e.g. 0.007)
    public var dCutoff: Double         // Cutoff frequency for derivative (e.g. 1.0 Hz)
    public var deadbandRadius: Double  // Deadband radius (normalized) to freeze micro-tremor (e.g. 0.01)
    
    // Internal state
    private var xPrev: Double?
    private var yPrev: Double?
    private var dxPrev: Double = 0.0
    private var dyPrev: Double = 0.0
    private var tPrev: TimeInterval?
    
    // Fixation lock state
    private var fixationAnchorX: Double?
    private var fixationAnchorY: Double?
    
    public init(
        minCutoff: Double = 0.6,
        beta: Double = 0.008,
        dCutoff: Double = 1.0,
        deadbandRadius: Double = 0.012
    ) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        self.deadbandRadius = deadbandRadius
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        xPrev = nil
        yPrev = nil
        dxPrev = 0.0
        dyPrev = 0.0
        tPrev = nil
        fixationAnchorX = nil
        fixationAnchorY = nil
    }
    
    public func filter(_ raw: GazePoint) -> GazePoint {
        lock.lock()
        defer { lock.unlock() }
        
        let t = raw.timestamp.timeIntervalSince1970
        guard let prevT = tPrev, let px = xPrev, let py = yPrev else {
            xPrev = raw.x
            yPrev = raw.y
            tPrev = t
            fixationAnchorX = raw.x
            fixationAnchorY = raw.y
            return raw
        }
        
        let dt = max(t - prevT, 0.001)
        tPrev = t
        
        // 1. Deadband check: if within fixation deadband radius of anchor, lock position
        if let ax = fixationAnchorX, let ay = fixationAnchorY {
            let distToAnchor = sqrt(pow(raw.x - ax, 2) + pow(raw.y - ay, 2))
            if distToAnchor < deadbandRadius {
                // Micro-tremor: hold steady at filtered position
                return GazePoint(x: px, y: py, confidence: raw.confidence, timestamp: raw.timestamp)
            } else {
                // Saccade detected: break out of deadband
                fixationAnchorX = raw.x
                fixationAnchorY = raw.y
            }
        }
        
        // 2. Filter derivative (velocity)
        let rawDx = (raw.x - px) / dt
        let rawDy = (raw.y - py) / dt
        let alphaD = smoothingFactor(dt: dt, cutoff: dCutoff)
        let dx = alphaD * rawDx + (1.0 - alphaD) * dxPrev
        let dy = alphaD * rawDy + (1.0 - alphaD) * dyPrev
        dxPrev = dx
        dyPrev = dy
        
        // 3. Adapt cutoff frequency based on movement speed
        let speed = sqrt(dx * dx + dy * dy)
        let cutoff = minCutoff + beta * speed
        
        // 4. Filter value
        let alpha = smoothingFactor(dt: dt, cutoff: cutoff)
        let filteredX = alpha * raw.x + (1.0 - alpha) * px
        let filteredY = alpha * raw.y + (1.0 - alpha) * py
        
        xPrev = filteredX
        yPrev = filteredY
        
        return GazePoint(
            x: filteredX,
            y: filteredY,
            confidence: raw.confidence,
            timestamp: raw.timestamp
        )
    }
    
    private func smoothingFactor(dt: Double, cutoff: Double) -> Double {
        let r = 2.0 * .pi * cutoff * dt
        return r / (r + 1.0)
    }
}
