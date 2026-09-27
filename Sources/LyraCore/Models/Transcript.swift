import Foundation

/// Represents a raw or processed speech recognition transcript event.
public struct Transcript: Sendable, Equatable {
    /// Recognized spoken text string
    public let text: String
    
    /// True if the recognizer considers this final for the utterance
    public let isFinal: Bool
    
    /// Confidence score if available
    public let confidence: Double
    
    /// Timestamp of recognition
    public let timestamp: Date
    
    public init(text: String, isFinal: Bool = false, confidence: Double = 1.0, timestamp: Date = Date()) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
    }
}
