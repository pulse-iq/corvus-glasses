import Foundation

/// Stage 1 configuration.
///
/// iOS has no process environment to read, so keys resolve in this order:
///   1. UserDefaults (set from the debug panel, handy for swapping keys on device)
///   2. `Secrets.swift` -- gitignored, copied from `Secrets.swift.example`
/// Model ids are overridable the same way so a new model can be benchmarked
/// without a rebuild.
enum CorvusConfig {
  // MARK: - Keys

  static var geminiAPIKey: String { resolve("corvus.geminiAPIKey", fallback: Secrets.geminiAPIKey) }
  static var openAIAPIKey: String { resolve("corvus.openAIAPIKey", fallback: Secrets.corvusOpenAIAPIKey) }
  static var anthropicAPIKey: String { resolve("corvus.anthropicAPIKey", fallback: Secrets.corvusAnthropicAPIKey) }

  // MARK: - Models
  //
  // Verify these against current provider docs before trusting benchmark
  // numbers; model ids move faster than this file does.

  static var geminiFlashLiteModel: String { resolve("corvus.model.geminiFlashLite", fallback: "gemini-2.5-flash-lite") }
  static var geminiFlashModel: String { resolve("corvus.model.geminiFlash", fallback: "gemini-2.5-flash") }
  static var openAIVisionModel: String { resolve("corvus.model.openAI", fallback: "gpt-5-mini") }
  static var anthropicVisionModel: String { resolve("corvus.model.anthropic", fallback: "claude-haiku-4-5") }

  // MARK: - Sampling

  /// Frames per second handed to the detector. The glasses stream at 24fps;
  /// everything above ~1fps is spend without extra signal, because a shopper
  /// holds a product for seconds, not frames.
  static var samplesPerSecond: Double { resolveDouble("corvus.samplesPerSecond", fallback: 1.0) }

  /// Longest edge of the JPEG sent to the model. 768 keeps a product label
  /// legible while staying inside the cheap image tier for every provider.
  static var frameMaxDimension: CGFloat { CGFloat(resolveDouble("corvus.frameMaxDimension", fallback: 768)) }

  static var frameJPEGQuality: CGFloat { CGFloat(resolveDouble("corvus.frameJPEGQuality", fallback: 0.7)) }

  /// Whether to open upstream's LiveKit voice call alongside the watcher.
  ///
  /// Off: Stage 2's architecture is undecided, and upstream's call routes
  /// through a hosted gateway we have no account on -- so every launch opened a
  /// room that could only fail, put "Gateway not configured" over the camera,
  /// and held the mic and radio for nothing. Flip it on to exercise the LiveKit
  /// path once we have a gateway of our own.
  static var useLiveKitCall: Bool {
    get { UserDefaults.standard.bool(forKey: "corvus.useLiveKitCall") }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.useLiveKitCall") }
  }

  /// Whether the watcher runs on the live camera screen at all.
  ///
  /// Off means no frames go to a vision model from that screen -- the switch is
  /// as much about spend as about clutter, since a watched trip is a detector
  /// call roughly every second and a half.
  static var watchOnCameraScreen: Bool {
    get { UserDefaults.standard.object(forKey: "corvus.watchOnCameraScreen") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.watchOnCameraScreen") }
  }

  /// Whether to draw the Stage 1 readout over the camera.
  ///
  /// On for development, because a silent screen cannot distinguish "working
  /// and correctly quiet" from "broken". Turn it off before a participant wears
  /// the glasses: a debug overlay changes how someone behaves on camera.
  static var showWatcherHUD: Bool {
    get { UserDefaults.standard.object(forKey: "corvus.showWatcherHUD") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.showWatcherHUD") }
  }

  /// Detector to use in the app. Benchmarking across the others happens
  /// offline, against saved frames.
  static var activeDetector: DetectorKind {
    get {
      guard let raw = UserDefaults.standard.string(forKey: "corvus.activeDetector"),
            let kind = DetectorKind(rawValue: raw)
      else { return .geminiFlashLite }
      return kind
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "corvus.activeDetector") }
  }

  /// Write every sampled frame to disk alongside its verdict. Off by default --
  /// it is how the offline benchmark corpus gets built, not something to leave
  /// running during a session.
  static var captureCorpus: Bool {
    get { UserDefaults.standard.bool(forKey: "corvus.captureCorpus") }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.captureCorpus") }
  }

  // MARK: - Resolution

  private static func resolve(_ key: String, fallback: String) -> String {
    if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
    return fallback.hasPrefix("YOUR_") ? "" : fallback
  }

  private static func resolveDouble(_ key: String, fallback: Double) -> Double {
    let v = UserDefaults.standard.double(forKey: key)
    return v > 0 ? v : fallback
  }
}
