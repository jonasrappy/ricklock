import AVFoundation
import AppKit
import CoreImage

enum CameraFailure: LocalizedError {
    case unavailable, permission, configuration, timeout, encoding
    var errorDescription: String? {
        switch self {
        case .unavailable: return "No camera is available. Rick is still watching."
        case .permission: return "Camera access is off. Allow RickLock in System Settings > Privacy & Security > Camera."
        case .configuration: return "The camera could not start. It may be in use by another app."
        case .timeout: return "The camera did not deliver a photo. Rickroll continues."
        case .encoding: return "The camera image could not be saved."
        }
    }
}

/// Captures one JPEG, then releases the camera. No audio or video is recorded.
final class BustedCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "app.ricklock.RickLock.camera")
    private let context = CIContext()
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var timeout: DispatchWorkItem?
    private var readyAfter = Date.distantFuture
    private var captured = false
    private var generation = UUID()

    func capture(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            self.cleanup()
            self.generation = UUID()
            let generation = self.generation
            self.completion = completion
            self.captured = false
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.finish(.failure(CameraFailure.permission)); return
            }
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video)
            guard let camera else { self.finish(.failure(CameraFailure.unavailable)); return }
            do {
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: self.queue)
                session.beginConfiguration()
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                guard session.canAddInput(input) else {
                    session.commitConfiguration(); self.finish(.failure(CameraFailure.configuration)); return
                }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    session.commitConfiguration(); self.finish(.failure(CameraFailure.configuration)); return
                }
                session.addOutput(output)
                session.commitConfiguration()
                self.session = session
                self.output = output
                self.readyAfter = .distantFuture
                session.startRunning()
                // Give auto-exposure a moment to settle instead of saving a black first frame.
                self.readyAfter = Date().addingTimeInterval(0.35)
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == generation, self.completion != nil else { return }
                    self.finish(.failure(CameraFailure.timeout))
                }
                self.timeout = timeout
                self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            } catch { self.finish(.failure(error)) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard completion != nil, !captured, Date() >= readyAfter,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        captured = true
        let generation = self.generation
        let image = CIImage(cvPixelBuffer: buffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [:])
        // Stop outside the delegate callback so capture-session shutdown cannot deadlock it.
        queue.async {
            guard self.generation == generation, self.completion != nil else { return }
            if let data { self.finish(.success(data)) }
            else { self.finish(.failure(CameraFailure.encoding)) }
        }
    }

    func cancel() { queue.async { self.generation = UUID(); self.completion = nil; self.cleanup() } }

    private func finish(_ result: Result<Data, Error>) {
        let callback = completion
        completion = nil
        cleanup()
        DispatchQueue.main.async { callback?(result) }
    }

    private func cleanup() {
        timeout?.cancel(); timeout = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        output = nil; session = nil
    }
}

enum PhotoArchive {
    static var directory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("capture", isDirectory: true)
    }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func save(_ data: Data) throws -> URL {
        try prepareDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let name = "Busted_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8)).jpg"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        return url
    }
}
