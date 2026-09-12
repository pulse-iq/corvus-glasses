import Foundation

/// "Hey Corvus". When on, the worker listens to the mission's microphone for
/// the wearer addressing Corvus by name and answers as an intercept in the
/// current conversation mode. Proof of concept: the listening is a mute
/// recognition session on the worker (`agent/corvus_wake.py`), not a wake-word
/// engine, and the setting travels in every heartbeat so it can be flipped
/// mid-mission.
enum WakeWord {
  static let defaultsKey = "corvus.wakeWord"
  static let phrase = "Hey Corvus"

  static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

  static let footer = "Say \u{201C}\(phrase)\u{201D} at any point in a mission to start a conversation. "
    + "The worker transcribes the mission to listen for it and asks a small model whether you meant it."
}
