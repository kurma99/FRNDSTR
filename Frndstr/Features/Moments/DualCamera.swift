@preconcurrency import AVFoundation
import UIKit

/// Captures a back + front photo pair, BeReal style.
/// - `multiCam`: both cameras stream at once (iPhone XS and later) and are captured together.
/// - `sequential`: single-camera devices; captures the back photo, flips to the front, captures again.
/// - `unavailable`: no camera (e.g. the Simulator) or access denied.
///
/// All session work runs on a private serial queue; the class is only touched through its async API.
nonisolated final class DualCamera: NSObject, @unchecked Sendable {
    enum Mode: Sendable {
        case multiCam, sequential
        /// No camera hardware (e.g. the Simulator).
        case unavailable
        /// The user declined camera access.
        case denied
    }

    enum CameraError: LocalizedError {
        case notConfigured, captureFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured: String(localized: "The camera isn't ready.")
            case .captureFailed: String(localized: "The photo couldn't be taken. Please try again.")
            }
        }
    }

    private let queue = DispatchQueue(label: "frndstr.dualcamera")
    private(set) var mode: Mode = .unavailable
    private var session: AVCaptureSession?
    private var backOutput = AVCapturePhotoOutput()
    private var frontOutput = AVCapturePhotoOutput()
    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    /// Keeps capture delegates alive until they finish.
    private var inFlight: [PhotoDelegate] = []

    // MARK: Setup

    /// Asks for camera access and builds the session, connecting it to the given preview layers.
    func configure(backLayer: AVCaptureVideoPreviewLayer, frontLayer: AVCaptureVideoPreviewLayer) async -> Mode {
        // Check for hardware first so devices without a camera never show a permission prompt.
        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else { return .unavailable }
        guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }

        let layers = UncheckedLayers(back: backLayer, front: frontLayer)
        return await withCheckedContinuation { continuation in
            queue.async {
                let mode = AVCaptureMultiCamSession.isMultiCamSupported
                    ? self.configureMultiCam(back: back, front: front, layers: layers)
                    : self.configureSequential(back: back, front: front, layers: layers)
                self.mode = mode
                continuation.resume(returning: mode)
            }
        }
    }

    private func configureMultiCam(back: AVCaptureDevice, front: AVCaptureDevice, layers: UncheckedLayers) -> Mode {
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        let inputs = buildMultiCam(session, back: back, front: front, layers: layers)
        session.commitConfiguration()

        // A connection failed or the formats are too expensive for this device: fall back to one camera.
        guard let inputs, session.hardwareCost <= 1 else {
            backOutput = AVCapturePhotoOutput()
            frontOutput = AVCapturePhotoOutput()
            return configureSequential(back: back, front: front, layers: layers)
        }
        self.session = session
        self.backInput = inputs.back
        self.frontInput = inputs.front
        return .multiCam
    }

    /// Adds inputs, outputs and manual connections. Call between begin/commitConfiguration.
    private func buildMultiCam(_ session: AVCaptureMultiCamSession, back: AVCaptureDevice, front: AVCaptureDevice,
                               layers: UncheckedLayers) -> (back: AVCaptureDeviceInput, front: AVCaptureDeviceInput)? {
        Self.selectMultiCamFormat(for: back, maxWidth: 1920)
        Self.selectMultiCamFormat(for: front, maxWidth: 1280)

        guard let backInput = try? AVCaptureDeviceInput(device: back),
              let frontInput = try? AVCaptureDeviceInput(device: front),
              session.canAddInput(backInput), session.canAddInput(frontInput),
              session.canAddOutput(backOutput), session.canAddOutput(frontOutput)
        else { return nil }

        session.addInputWithNoConnections(backInput)
        session.addInputWithNoConnections(frontInput)
        session.addOutputWithNoConnections(backOutput)
        session.addOutputWithNoConnections(frontOutput)

        func connect(_ input: AVCaptureDeviceInput, position: AVCaptureDevice.Position,
                     output: AVCapturePhotoOutput, layer: AVCaptureVideoPreviewLayer) -> Bool {
            guard let port = input.ports(for: .video, sourceDeviceType: input.device.deviceType, sourceDevicePosition: position).first
            else { return false }
            let photo = AVCaptureConnection(inputPorts: [port], output: output)
            let preview = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            guard session.canAddConnection(photo), session.canAddConnection(preview) else { return false }
            session.addConnection(photo)
            session.addConnection(preview)
            for connection in [photo, preview] where connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            return true
        }

        layers.back.setSessionWithNoConnection(session)
        layers.front.setSessionWithNoConnection(session)
        guard connect(backInput, position: .back, output: backOutput, layer: layers.back),
              connect(frontInput, position: .front, output: frontOutput, layer: layers.front)
        else { return nil }
        return (backInput, frontInput)
    }

    private func configureSequential(back: AVCaptureDevice, front: AVCaptureDevice, layers: UncheckedLayers) -> Mode {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo
        backOutput = AVCapturePhotoOutput()
        guard let backInput = try? AVCaptureDeviceInput(device: back),
              session.canAddInput(backInput), session.canAddOutput(backOutput)
        else {
            session.commitConfiguration()
            return .unavailable
        }
        session.addInput(backInput)
        session.addOutput(backOutput)
        session.commitConfiguration()

        layers.back.session = session
        self.session = session
        self.backInput = backInput
        self.frontInput = try? AVCaptureDeviceInput(device: front)
        return .sequential
    }

    /// Multi-cam needs formats flagged `isMultiCamSupported`; prefer the largest one within `maxWidth`.
    private static func selectMultiCamFormat(for device: AVCaptureDevice, maxWidth: Int32) {
        let candidates = device.formats.filter {
            $0.isMultiCamSupported && CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= maxWidth
        }
        guard let best = candidates.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }), (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = best
        device.unlockForConfiguration()
    }

    // MARK: Running

    func start() {
        queue.async { if self.session?.isRunning == false { self.session?.startRunning() } }
    }

    func stop() {
        queue.async { self.session?.stopRunning() }
    }

    /// Takes the back and front photo. In sequential mode the preview briefly shows the front camera.
    func capture() async throws -> (back: UIImage, front: UIImage) {
        switch mode {
        case .unavailable, .denied:
            throw CameraError.notConfigured
        case .multiCam:
            async let back = photo(from: backOutput)
            async let front = photo(from: frontOutput)
            return try await (back, front)
        case .sequential:
            let back = try await photo(from: backOutput)
            try await switchSequentialCamera(toFront: true)
            // Give auto exposure a moment to settle on the new camera.
            try await Task.sleep(for: .milliseconds(450))
            let front = try await photo(from: backOutput)
            try await switchSequentialCamera(toFront: false)
            return (back, front)
        }
    }

    private func switchSequentialCamera(toFront: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let session = self.session, let backInput = self.backInput, let frontInput = self.frontInput else {
                    continuation.resume(throwing: CameraError.notConfigured)
                    return
                }
                session.beginConfiguration()
                session.removeInput(toFront ? backInput : frontInput)
                let next = toFront ? frontInput : backInput
                if session.canAddInput(next) { session.addInput(next) }
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    private func photo(from output: AVCapturePhotoOutput) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                let delegate = PhotoDelegate { result, delegate in
                    self.queue.async { self.inFlight.removeAll { $0 === delegate } }
                    continuation.resume(with: result)
                }
                self.inFlight.append(delegate)
                output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
            }
        }
    }
}

/// Preview layers belong to UIKit views; they're only handed to the session queue during setup.
private nonisolated struct UncheckedLayers: @unchecked Sendable {
    let back: AVCaptureVideoPreviewLayer
    let front: AVCaptureVideoPreviewLayer
}

private nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<UIImage, Error>, PhotoDelegate) -> Void

    init(completion: @escaping (Result<UIImage, Error>, PhotoDelegate) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(error), self)
        } else if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
            completion(.success(image), self)
        } else {
            completion(.failure(DualCamera.CameraError.captureFailed), self)
        }
    }
}
