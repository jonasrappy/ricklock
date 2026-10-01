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
    private let queue = DispatchQueue(label: "app.ricklock.RickLock.camera", qos: .userInitiated)
    private let context = CIContext()
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var timeout: DispatchWorkItem?
    private var captured = false
    private var generation = UUID()
    private var firstFrameAt: TimeInterval?

    func prepare(completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async {
            guard self.completion == nil else { return }
            let result = Result { try self.configure() }
            if case .failure = result { self.cleanup() }
            DispatchQueue.main.async { completion?(result) }
        }
    }

    private func configure() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw CameraFailure.permission }
        guard session == nil else { return }
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let camera else { throw CameraFailure.unavailable }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // Prefer YUV luma planes; leave other devices in their native format.
        output.videoSettings = nil
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { throw CameraFailure.configuration }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CameraFailure.configuration }
        session.addOutput(output)
        if let format = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].first(where: { output.availableVideoPixelFormatTypes.contains($0) }) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        }
        self.session = session
        self.output = output
    }

    func capture(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            guard self.completion == nil else { return }
            self.generation = UUID()
            let generation = self.generation
            self.completion = completion
            self.captured = false
            self.firstFrameAt = nil
            do {
                try self.configure()
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == generation, self.completion != nil else { return }
                    self.finish(.failure(CameraFailure.timeout))
                }
                self.timeout = timeout
                self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
                self.session?.startRunning()
            } catch { self.finish(.failure(error)) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === self.output, completion != nil, !captured,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if firstFrameAt == nil { firstFrameAt = now }
        // Skip near-black startup frames only; never wait more than 150 ms for exposure.
        if now - firstFrameAt! < 0.15, let brightness = Self.brightness(of: buffer), brightness < 0.05 { return }
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

    func cancel(completion: (() -> Void)? = nil) {
        queue.async {
            self.generation = UUID()
            self.completion = nil
            self.cleanup()
            DispatchQueue.main.async { completion?() }
        }
    }

    private static func brightness(of buffer: CVPixelBuffer) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var total = 0.0
        for y in 0..<16 {
            for x in 0..<16 { total += Double(bytes[(y * height / 16) * stride + x * width / 16]) }
        }
        let average = total / 256
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? max(0, average - 16) / 219 : average / 255
    }

    private func finish(_ result: Result<Data, Error>) {
        let callback = completion
        completion = nil
        DispatchQueue.main.async { callback?(result) }
        // Deliver the photo without waiting for synchronous camera shutdown.
        cleanup()
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
