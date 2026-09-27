import Foundation

/// Protocol defining speech transcription and voice input.
/// Provides a stream of transcripts without performing computer actions directly.
public protocol SpeechProvider: Sendable {
    /// Starts speech recognition listening
    func start() async throws
    
    /// Stops speech recognition listening
    func stop() async
    
    /// Stream of incoming transcribed speech
    var transcriptStream: AsyncStream<Transcript> { get }
}
