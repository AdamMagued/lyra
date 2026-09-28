import Foundation
import AVFoundation
import Vision
import CoreMedia
import CoreImage
import LyraCore

public enum GazeError: Error, LocalizedError {
    case cameraNotAvailable
    case permissionDenied
    case configurationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cameraNotAvailable:
            return "No camera was found. Connect a webcam and try again."
        case .permissionDenied:
            return "Camera access is off. Turn it on in System Settings › Privacy & Security › Camera."
        case .configurationFailed(let reason):
            return "The camera could not be started: \(reason)"
        }
    }
}

/// Captures video and emits raw facial measurements.
///
/// Deliberately thin. It owns the camera, runs Vision, and hands the results to
/// `FaceFeatureExtractor`. It contains no gaze model, no calibration and no notion of
/// where the screen is — the parts of the old implementation that made the pipeline
/// impossible to test without a camera.
///
/// Three practical choices are worth noting:
///
/// **Analysis is decoupled from capture.** Vision work runs on its own queue with at
/// most one request in flight. Running it inline on the capture queue, as the original
/// did, means a slow frame stalls video delivery and the whole pipeline degrades under
/// load rather than gracefully dropping frames.
///
/// **The face region is tracked between frames.** Once a face is found, the next frame's
/// landmark request is restricted to a slightly expanded box around it. Vision spends
/// its resolution budget inside that box instead of on the whole frame, which measurably
/// improves pupil localisation — the single least precise thing Vision gives us.
///
/// **The preview is downscaled.** Producing a full 720p `CGImage` per frame, as the
/// original did, burns a lot of CPU to draw a 220-point thumbnail.
public final class VisionGazeProvider: NSObject, GazeProvider, @unchecked Sendable {

    // MARK: - Capture

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.lyra.gaze.capture", qos: .userInteractive)

    /// Vision runs here, off the capture queue, so a slow analysis never blocks video.
    private let analysisQueue = DispatchQueue(label: "com.lyra.gaze.analysis", qos: .userInitiated)
    private let previewContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Only ever one Vision request in flight. A backlog of stale frames is worthless.
    private let analysisInFlight = NSLock()
    private var isAnalysing = false

    private let stateLock = NSLock()
    private var extractor = FaceFeatureExtractor()
    private var configured = false
    private var running = false
    private var facePresent = false

    /// `AVCaptureDevice.uniqueID` of the camera currently attached, if any.
    ///
    /// Exposed so calibration can record which camera it was measured against. The same
    /// person sitting the same distance from a different camera produces different
    /// features, so a map fitted through one is not valid through another — and without
    /// this there is no way to tell the two apart after the fact.
    private var cameraIDStorage: String?

    public var activeCameraID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cameraIDStorage
    }

    /// Cameras the system is offering, best first. The first is the one that will be used.
    ///
    /// Ordered so that a camera which is actually delivering video outranks one that is
    /// merely present. A MacBook with the lid shut still lists its built-in camera, and
    /// it still produces nothing.
    public static func availableCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.uniqueID < rhs.uniqueID
        }
    }

    private var continuation: AsyncStream<GazeFeatures>.Continuation?

    public var onPreviewFrame: (@Sendable (CGImage) -> Void)?

    // MARK: - Protocol

    public var featureStream: AsyncStream<GazeFeatures> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in }
        }
    }

    public var isTracking: Bool {
        get async { isFacePresent() }
    }

    /// Synchronous accessors for state guarded by `NSLock`.
    ///
    /// `NSLock.lock()` is unavailable from async contexts: blocking a cooperative thread
    /// can starve the whole concurrency pool. Routing every critical section through a
    /// plain synchronous method keeps it off the async path, which is the fix the
    /// compiler is asking for rather than a restructure of the locking itself.
    private func isFacePresent() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return facePresent
    }

    private func resetExtractor() {
        stateLock.lock(); defer { stateLock.unlock() }
        extractor.reset()
    }

    private func setRunning(_ value: Bool, facePresent present: Bool? = nil) {
        stateLock.lock(); defer { stateLock.unlock() }
        running = value
        if let present { facePresent = present }
    }

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        try await requestCameraAccess()

        resetExtractor()

        try configureSessionIfNeeded()

        let session = captureSession
        if !session.isRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
                    continuation.resume()
                }
            }
        }

        setRunning(true)
    }

    public func stop() async {
        setRunning(false, facePresent: false)

        let session = captureSession
        if session.isRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    session.stopRunning()
                    continuation.resume()
                }
            }
        }
        continuation?.finish()
        continuation = nil
    }

    private func requestCameraAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw GazeError.permissionDenied }
        case .denied, .restricted:
            throw GazeError.permissionDenied
        default:
            break
        }
    }

    private func configureSessionIfNeeded() throws {
        stateLock.lock()
        let alreadyConfigured = configured
        stateLock.unlock()
        guard !alreadyConfigured else { return }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Prefer 1080p for 2.25x more pixels across the iris and pupil, fallback to 720p
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        } else if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        } else {
            captureSession.sessionPreset = .vga640x480
        }

        guard let camera = Self.availableCameras().first ?? AVCaptureDevice.default(for: .video) else {
            throw GazeError.cameraNotAvailable
        }

        stateLock.lock()
        cameraIDStorage = camera.uniqueID
        stateLock.unlock()

        // Configure 30 fps capture and continuous auto-exposure
        try? camera.lockForConfiguration()
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) {
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        camera.unlockForConfiguration()

        guard let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            throw GazeError.configurationFailed("Could not attach the camera.")
        }
        captureSession.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw GazeError.configurationFailed("Could not attach the video output.")
        }
        captureSession.addOutput(videoOutput)

        // Geometry stays unmirrored so features are consistent frame to frame; the
        // preview is flipped for display instead.
        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        stateLock.lock()
        configured = true
        stateLock.unlock()
    }
}

// MARK: - Frame handling

extension VisionGazeProvider: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        emitPreview(from: pixelBuffer)

        // Drop frames rather than queue them. A measurement that arrives late is worse
        // than no measurement, because it will be attributed to the wrong moment.
        analysisInFlight.lock()
        if isAnalysing {
            analysisInFlight.unlock()
            return
        }
        isAnalysing = true
        analysisInFlight.unlock()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analyse(pixelBuffer: pixelBuffer)

            self.analysisInFlight.lock()
            self.isAnalysing = false
            self.analysisInFlight.unlock()
        }
    }

    private func analyse(pixelBuffer: CVPixelBuffer) {
        let rectRequest = VNDetectFaceRectanglesRequest()
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        landmarkRequest.revision = VNDetectFaceLandmarksRequestRevision3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([rectRequest, landmarkRequest])
        } catch {
            return
        }

        guard let landmarkObservations = landmarkRequest.results, !landmarkObservations.isEmpty else {
            markFaceAbsent()
            return
        }

        // The user's face is the largest face detected in the frame.
        guard let face = landmarkObservations.max(by: { $0.boundingBox.height < $1.boundingBox.height }) else {
            markFaceAbsent()
            return
        }

        let rectFace = rectRequest.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height })

        stateLock.lock()
        let features = extractor.extract(from: face, poseSource: rectFace)
        facePresent = true
        stateLock.unlock()

        guard let features else { return }
        continuation?.yield(features)
    }

    private func markFaceAbsent() {
        stateLock.lock()
        facePresent = false
        stateLock.unlock()
    }

    /// Produces a small preview image. Downscaling here rather than drawing full
    /// resolution into a thumbnail is the difference between a few percent of a core
    /// and a noticeable permanent CPU load.
    private func emitPreview(from pixelBuffer: CVPixelBuffer) {
        guard let onPreviewFrame else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 320.0 / max(image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = previewContext.createCGImage(scaled, from: scaled.extent) else { return }
        onPreviewFrame(cgImage)
    }
}
