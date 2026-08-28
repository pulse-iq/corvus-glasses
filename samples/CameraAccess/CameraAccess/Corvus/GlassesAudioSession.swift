import AVFoundation
import Foundation

/// How the interview borrows the device's audio while it runs.
///
/// Measured on Ray-Ban Metas with DAT streaming video: both work, and DAT keeps
/// delivering frames throughout, so this is a quality trade rather than a
/// capability one.
enum AudioRouteMode: String, CaseIterable, Codable {
  /// Glasses speaker and glasses microphone. HFP narrows the whole route to
  /// call quality, so the question sounds like a phone call -- but the mic sits
  /// on the wearer's temple, which is worth far more than bandwidth once there
  /// is aisle noise to reject.
  case glassesBothWays
  /// Glasses speaker at full bandwidth, answer captured on the phone. Better
  /// fidelity for transcription, but the phone hears the room rather than the
  /// wearer, and a pocketed phone hears mostly cloth.
  case glassesSpeakerPhoneMic

  var label: String {
    switch self {
    case .glassesBothWays: return "Glasses mic + speaker"
    case .glassesSpeakerPhoneMic: return "Glasses speaker, phone mic"
    }
  }
}

/// Takes the audio route for the duration of an interview and gives it back.
///
/// The reason this exists rather than a couple of inline `setCategory` calls is
/// input selection. A participant may well have earbuds connected -- the probe
/// found `iPhone Microphone`, `AirPods Pro` and `RB Meta` all offered at once --
/// and "first Bluetooth input" would quietly interview them through the wrong
/// device. The glasses are chosen by name, and what actually got selected is
/// recorded so a bad session can be explained afterwards rather than guessed at.
@MainActor
enum GlassesAudioSession {
  /// `.allowBluetooth` was renamed in iOS 26; the app targets 17, so both
  /// spellings have to exist to compile warning-free against the new SDK.
  static var hfpOption: AVAudioSession.CategoryOptions {
    if #available(iOS 26.0, *) { return .allowBluetoothHFP }
    return .allowBluetooth
  }

  struct Activation {
    let mode: AudioRouteMode
    /// What iOS actually chose, for the interview record.
    let inputName: String
    let outputName: String
    /// False when the glasses were asked for and something else answered.
    let matchedGlasses: Bool
  }

  enum AudioError: LocalizedError {
    case configurationFailed(String)

    var errorDescription: String? {
      switch self {
      case .configurationFailed(let why): return "Audio session failed: \(why)"
      }
    }
  }

  @discardableResult
  static func activate(mode: AudioRouteMode) throws -> Activation {
    let session = AVAudioSession.sharedInstance()
    let options: AVAudioSession.CategoryOptions = mode == .glassesBothWays
      ? [hfpOption, .allowBluetoothA2DP, .duckOthers]
      // Withholding the HFP option is what keeps output on A2DP: offering it
      // lets iOS pull the whole route down to call quality to get a mic it was
      // never asked for.
      : [.allowBluetoothA2DP, .duckOthers]

    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
      try session.setActive(true)
    } catch {
      throw AudioError.configurationFailed(error.localizedDescription)
    }

    var matched = false
    switch mode {
    case .glassesBothWays:
      if let glasses = preferredGlassesInput(from: session.availableInputs ?? []) {
        try? session.setPreferredInput(glasses)
        matched = isGlasses(glasses.portName)
      }
    case .glassesSpeakerPhoneMic:
      if let builtIn = (session.availableInputs ?? []).first(where: { $0.portType == .builtInMic }) {
        try? session.setPreferredInput(builtIn)
      }
      matched = session.currentRoute.outputs.contains { isGlasses($0.portName) }
    }

    return Activation(
      mode: mode,
      inputName: session.currentRoute.inputs.first?.portName ?? "none",
      outputName: session.currentRoute.outputs.first?.portName ?? "none",
      matchedGlasses: matched)
  }

  static func deactivate() {
    try? AVAudioSession.sharedInstance()
      .setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// Glasses first, any other Bluetooth headset second, built-in mic last.
  /// Falling through rather than failing keeps a session recoverable: a worse
  /// microphone still produces data, a thrown error produces nothing.
  private static func preferredGlassesInput(
    from inputs: [AVAudioSessionPortDescription]
  ) -> AVAudioSessionPortDescription? {
    if let glasses = inputs.first(where: { isGlasses($0.portName) }) { return glasses }
    if let bluetooth = inputs.first(where: {
      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
    }) { return bluetooth }
    return inputs.first { $0.portType == .builtInMic }
  }

  static func isGlasses(_ portName: String) -> Bool {
    let hints = CorvusConfig.glassesAudioNameHints
    let name = portName.lowercased()
    return hints.contains { !$0.isEmpty && name.contains($0.lowercased()) }
  }
}
