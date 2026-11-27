import AVFoundation

/// Owns the built-in camera. External and Continuity cameras are never used, so nobody can
/// feed the recognizer from a different device.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "faceunlock.camera.session")
    private let frameQueue = DispatchQueue(label: "faceunlock.camera.frames", qos: .userInitiated)
    private var handler: ((CVPixelBuffer, TimeInterval) -> Void)?

    static var builtInCamera: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                         position: .unspecified).devices.first
    }

    static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// `handler` runs on a background queue. Late frames are dropped, so it can be slow.
    func start(_ handler: @escaping (CVPixelBuffer, TimeInterval) -> Void) {
        frameQueue.async { self.handler = handler }
        sessionQueue.async {
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// Sets the session up without switching the camera on.
    func prepare() {
        sessionQueue.async { if self.session.inputs.isEmpty, Self.isAuthorized { self.configure() } }
    }

    func stop() {
        frameQueue.async { self.handler = nil }
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        guard let device = Self.builtInCamera, let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            // Analysis uses the true image; only the on-screen preview is mirrored.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler?(pixels, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}
