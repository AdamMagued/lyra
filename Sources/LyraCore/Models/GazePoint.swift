import Foundation

/// Represents a 2D gaze sample mapped to normalized coordinates (0.0...1.0)
/// or absolute screen coordinates, with associated confidence and timestamp.
public struct GazePoint: Sendable, Equatable {
    /// Normalized horizontal gaze point [0.0, 1.0] from screen left to right
    public let x: Double
    
    /// Normalized vertical gaze point [0.0, 1.0] from screen top to bottom
    public let y: Double
    
    /// Estimated confidence score in range [0.0, 1.0]
    public let confidence: Double
    
    /// Exact timestamp when the sample was computed
    public let timestamp: Date
    
    public init(x: Double, y: Double, confidence: Double, timestamp: Date = Date()) {
        self.x = min(max(x, 0.0), 1.0)
        self.y = min(max(y, 0.0), 1.0)
        self.confidence = min(max(confidence, 0.0), 1.0)
        self.timestamp = timestamp
    }
    
    /// Converts normalized coordinates into absolute screen pixel coordinates
    public func toScreenCoordinates(screenWidth: Double, screenHeight: Double) -> (x: Double, y: Double) {
        return (x: x * screenWidth, y: y * screenHeight)
    }
}
