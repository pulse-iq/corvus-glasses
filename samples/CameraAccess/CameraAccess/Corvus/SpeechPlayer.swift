import AVFoundation
import Foundation

/// Speaks a line and returns when the last word has actually finished.
///
/// The waiting is the point. Recording must not start until the question has
/// stopped playing, or the glasses hear themselves and the first seconds of the
/// answer are the question -- which is exactly the echo problem that a
/// half-duplex design exists to avoid.
@MainActor
final class SpeechPlayer: NSObject {
  private let synthesizer = AVSpeechSynthesizer()
  private var continuation: CheckedContinuation<Void, Never>?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Enhanced voices are a large quality jump over the default and cost
  /// nothing, but they are a user-installed download -- so this is a
  /// preference, not a requirement.
  private static var voice: AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
    return voices.first { $0.quality == .premium }
      ?? voices.first { $0.quality == .enhanced }
      ?? AVSpeechSynthesisVoice(language: "en-US")
  }

  func say(_ text: String) async {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice
    // Slightly under default. A question asked at full speed into someone's ear
    // mid-aisle reads as an alarm rather than an interviewer.
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
    utterance.postUtteranceDelay = 0.15

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      // A pending continuation here would mean two overlapping questions, which
      // the interview flow does not do; release it rather than leak the task.
      finish()
      continuation = cont
      synthesizer.speak(utterance)
    }
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    finish()
  }

  private func finish() {
    continuation?.resume()
    continuation = nil
  }
}

extension SpeechPlayer: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.finish() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.finish() }
  }
}
