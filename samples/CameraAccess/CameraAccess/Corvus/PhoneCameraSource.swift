import AVFoundation
import CoreVideo
import UIKit

/// The iPhone's back camera as a stand-in for the glasses.
///
/// Stage 1 is a vision problem, not a wearables problem: prompt wording,
/// confidence thresholds and streak length can all be tuned by pointing a phone
/// at a kitchen shelf. Owning a small capture session here -- rather than
/// borrowing the call's camera track -- keeps the watcher testable without a
/// room, a server, or the glasses on your face.
final class PhoneCameraSource: NSObject, ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var error: String?

  /// Every captured frame, on the video queue. The coordinator throttles.
  var onFrame: ((CVPixelBuffer) -> Void)?

  let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "com.corvus.camera")
  private var configured = false

  func start() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      guard let self else { return }
      guard granted else {
        Task { @MainActor in self.error = "Camera permission denied" }
        return
      }
      self.queue.async { self.configureAndRun() }
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      if self.session.isRunning { self.session.stopRunning() }
      Task { @MainActor in self.isRunning = false }
    }
  }

  private func configureAndRun() {
    if !configured {
      session.beginConfiguration()
      // 720p: matches what the glasses deliver, so thresholds tuned here mean
      // something there. The sampler downscales before the model sees it anyway.
      session.sessionPreset = .hd1280x720

      guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
      else {
        session.commitConfiguration()
        Task { @MainActor in self.error = "No usable back camera" }
        return
      }
      session.addInput(input)

      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      // The watcher wants the newest frame, never a backlog: a stale frame
      // describes a moment the shopper has already moved past.
      output.alwaysDiscardsLateVideoFrames = true
      output.setSampleBufferDelegate(self, queue: queue)
      guard session.canAddOutput(output) else {
        session.commitConfiguration()
        Task { @MainActor in self.error = "Could not attach video output" }
        return
      }
      session.addOutput(output)
      session.commitConfiguration()
      configured = true
    }

    if !session.isRunning { session.startRunning() }
    Task { @MainActor in
      self.error = nil
      self.isRunning = true
    }
  }
}

extension PhoneCameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    onFrame?(pixelBuffer)
  }
}
