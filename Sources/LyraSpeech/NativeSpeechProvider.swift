import Foundation
import Speech
import AVFoundation
import LyraCore

public enum SpeechError: Error, LocalizedError {
    case speechNotAvailable
    case permissionDenied(String)
    case audioEngineFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .speechNotAvailable:
            return "Speech recognition is not available on this device or language."
        case .permissionDenied(let reason):
            return "Speech or Microphone permission denied: \(reason)"
        case .audioEngineFailed(let msg):
            return "Audio engine failure: \(msg)"
        }
    }
}

/// Native macOS speech recognition provider using Apple Speech framework and AVAudioEngine.
public final class NativeSpeechProvider: SpeechProvider, @unchecked Sendable {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var continuation: AsyncStream<Transcript>.Continuation?
    private var isListening: Bool = false
    
    public var transcriptStream: AsyncStream<Transcript> {
        AsyncStream { [weak self] cont in
            self?.continuation = cont
            cont.onTermination = { @Sendable _ in }
        }
    }
    
    public init() {}
    
    public func start() async throws {
        guard !isListening else { return }
        
        // 1. Check & Request Speech Authorization
        let currentSpeechStatus = SFSpeechRecognizer.authorizationStatus()
        let authStatus: SFSpeechRecognizerAuthorizationStatus
        if currentSpeechStatus == .notDetermined {
            authStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            authStatus = currentSpeechStatus
        }
        
        guard authStatus == .authorized else {
            throw SpeechError.permissionDenied("Speech Recognition not authorized")
        }
        
        // 2. Check & Request Microphone Authorization
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard micGranted else {
                throw SpeechError.permissionDenied("Microphone access not granted")
            }
        } else if micStatus != .authorized {
            throw SpeechError.permissionDenied("Microphone access not authorized")
        }
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw SpeechError.speechNotAvailable
        }
        
        try startAudioEngineAndRecognition(recognizer: recognizer)
        isListening = true
    }
    
    public func stop() async {
        guard isListening else { return }
        isListening = false
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        continuation?.finish()
        continuation = nil
    }
    
    private func startAudioEngineAndRecognition(recognizer: SFSpeechRecognizer) throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.recognitionRequest = request
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            throw SpeechError.audioEngineFailed(error.localizedDescription)
        }
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                let confidence = Double(result.bestTranscription.segments.last?.confidence ?? 1.0)
                
                let transcript = Transcript(
                    text: text,
                    isFinal: isFinal,
                    confidence: confidence,
                    timestamp: Date()
                )
                self.continuation?.yield(transcript)
            }
            
            if (error != nil || (result?.isFinal ?? false)) && self.isListening {
                self.restartRecognitionTask(recognizer: recognizer)
            }
        }
    }
    
    private func restartRecognitionTask(recognizer: SFSpeechRecognizer) {
        guard isListening else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                let confidence = Double(result.bestTranscription.segments.last?.confidence ?? 1.0)
                
                let transcript = Transcript(
                    text: text,
                    isFinal: isFinal,
                    confidence: confidence,
                    timestamp: Date()
                )
                self.continuation?.yield(transcript)
            }
            if (error != nil || (result?.isFinal ?? false)) && self.isListening {
                self.restartRecognitionTask(recognizer: recognizer)
            }
        }
    }
}
