import CoreImage
import CoreVideo
import UIKit

/// Turns a 24fps camera feed into the occasional small JPEG.
///
/// Two jobs, both about not wasting money: drop all but ~1 frame per second,
/// and shrink what survives. A shopper holds a product for seconds, so the
/// discarded frames carry no information the kept ones lack.
final class FrameSampler {
  private let context = CIContext(options: [.useSoftwareRenderer: false])
  private var lastSampledAt: Date?

  /// True when enough time has passed to spend another detector call. Checked
  /// before any image work so rejected frames cost nothing.
  func shouldSample(at now: Date = Date()) -> Bool {
    let interval = 1.0 / max(CorvusConfig.samplesPerSecond, 0.05)
    guard let last = lastSampledAt else {
      lastSampledAt = now
      return true
    }
    guard now.timeIntervalSince(last) >= interval else { return false }
    lastSampledAt = now
    return true
  }

  func reset() {
    lastSampledAt = nil
  }

  func jpeg(from pixelBuffer: CVPixelBuffer) -> Data? {
    encode(CIImage(cvPixelBuffer: pixelBuffer))
  }

  func jpeg(from image: UIImage) -> Data? {
    if let ci = image.ciImage { return encode(ci) }
    guard let cg = image.cgImage else { return nil }
    // Bake the UIImage's orientation into the pixels: the model has no
    // metadata to consult, and a sideways frame is a different question.
    return encode(CIImage(cgImage: cg).oriented(image.imageOrientation.cgOrientation))
  }

  private func encode(_ image: CIImage) -> Data? {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return nil }

    let longest = max(extent.width, extent.height)
    let scale = min(1, CorvusConfig.frameMaxDimension / longest)
    let scaled = scale < 1 ? image.transformed(by: .init(scaleX: scale, y: scale)) : image

    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cg).jpegData(compressionQuality: CorvusConfig.frameJPEGQuality)
  }
}

private extension UIImage.Orientation {
  var cgOrientation: CGImagePropertyOrientation {
    switch self {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    case .upMirrored: return .upMirrored
    case .downMirrored: return .downMirrored
    case .leftMirrored: return .leftMirrored
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
  }
}
