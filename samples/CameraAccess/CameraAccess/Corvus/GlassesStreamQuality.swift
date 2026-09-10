import Combine
import Foundation
import MWDATCamera

/// What the glasses are actually sending, as opposed to what was asked for.
/// The ladder steps a request down without saying so; this is how Settings
/// tells Wi-Fi from Bluetooth. Written by the stream view model, read by the
/// Glasses stream section in Settings.
@MainActor
final class GlassesStreamStatus: ObservableObject {
  static let shared = GlassesStreamStatus()
  @Published private(set) var delivered: CGSize?
  private(set) var since: CFAbsoluteTime = 0

  func note(_ size: CGSize) {
    guard delivered != size else { return }
    delivered = size
    since = CFAbsoluteTimeGetCurrent()
  }

  func clear() { delivered = nil }

  var heldFor: Double { CFAbsoluteTimeGetCurrent() - since }
}

/// The one glasses stream setting Corvus exposes.
///
/// There is no transport switch in the DAT SDK. It picks the link from the
/// tier the app asks for: high requests a Wi-Fi lease (Wi-Fi Aware on iOS 26,
/// which needs the wifi-aware entitlement and the WiFiAwareServices plist
/// entry), while medium and low ride Bluetooth Classic. When Wi-Fi is not
/// available the glasses step a high request down to 504x896 on their own, so
/// the link is inferred from what actually arrives rather than chosen.
enum GlassesStreamQuality: String, CaseIterable, Identifiable {
  case high, medium, low

  static let defaultsKey = "corvus.glassesStreamQuality"

  var id: String { rawValue }

  var resolution: StreamingResolution {
    switch self {
    case .high: return .high
    case .medium: return .medium
    case .low: return .low
    }
  }

  var label: String {
    switch self {
    case .high: return "High · 720p · Wi-Fi"
    case .medium: return "Medium · 504p · Bluetooth"
    case .low: return "Low · 360p · Bluetooth"
    }
  }

  static var stored: GlassesStreamQuality {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(GlassesStreamQuality.init(rawValue:)) ?? .high
  }

  /// One line for the screen about the link, from what the glasses delivered.
  /// Bluetooth Classic can hold 720p for the first half minute before the
  /// ladder steps it down, so Wi-Fi is only claimed once 720p has lasted
  /// longer than that.
  /// Bluetooth Classic has never held 720p past about half a minute in any
  /// run; Wi-Fi has held it for minutes. So sustained 720p is the Wi-Fi tell.
  /// (The phone's nan0 interface is not one: it never reported running from
  /// inside the app even while Wi-Fi carried 720p.) A 504 or 360 picture
  /// after a High request is the ladder having stepped down, which happens
  /// both when Wi-Fi never came up and when a heavy request (30 fps) outgrows
  /// the Wi-Fi link, so it is reported as a step-down rather than as a
  /// verdict on the transport.
  static func linkStatus(requested: GlassesStreamQuality, delivered: CGSize?, heldFor seconds: Double) -> String {
    guard let delivered else { return "Waiting for glasses video" }
    let size = "\(Int(delivered.width))x\(Int(delivered.height))"
    if delivered.height >= 1280 {
      return seconds > 45 ? "\(size) over Wi-Fi" : "\(size), confirming link"
    }
    if requested == .high { return "\(size), stepped down from 720p" }
    return "\(size) over Bluetooth"
  }
}

/// Requested frame rate. Only these five are legal; the SDK snaps anything
/// else down to a rung. Fewer frames give each one more of the link, which is
/// what sharpens Bluetooth frames; the watcher samples once a second anyway.
enum GlassesStreamFrameRate: Int, CaseIterable, Identifiable {
  case fps2 = 2, fps7 = 7, fps15 = 15, fps24 = 24, fps30 = 30

  static let defaultsKey = "corvus.glassesStreamFrameRate"

  var id: Int { rawValue }
  var label: String { "\(rawValue) fps" }

  static var stored: GlassesStreamFrameRate {
    let raw = UserDefaults.standard.integer(forKey: defaultsKey)
    return GlassesStreamFrameRate(rawValue: raw) ?? .fps15
  }
}

/// Wire codec between glasses and phone. HEVC is what lets 720p fit on the
/// link at all; raw is what the 0.4 SDK used and arrives already decoded.
enum GlassesStreamCodec: String, CaseIterable, Identifiable {
  case hevc, raw

  static let defaultsKey = "corvus.glassesStreamCodec"

  var id: String { rawValue }

  var videoCodec: VideoCodec {
    switch self {
    case .hevc: return .hvc1
    case .raw: return .raw
    }
  }

  var label: String {
    switch self {
    case .hevc: return "HEVC"
    case .raw: return "Raw"
    }
  }

  static var stored: GlassesStreamCodec {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(GlassesStreamCodec.init(rawValue:)) ?? .hevc
  }
}
