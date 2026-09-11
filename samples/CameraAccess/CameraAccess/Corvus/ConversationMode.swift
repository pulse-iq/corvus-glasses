import Foundation

/// How a mission talks to the wearer. Both modes share the room, the worker,
/// the recording and the transcript; they differ in what listens and speaks.
enum ConversationMode: String, CaseIterable, Identifiable {
  /// One speech-to-speech model holds the floor: sub-second, interruptible.
  case realtime
  /// pulseiq-live-kit's pipeline: speech recognition, a text model and a
  /// synthesized voice in turn. About two seconds between turns, no barge-in,
  /// the opening question spoken word for word, and follow-ups steered by the
  /// study's probe questions.
  case turnBased

  static let defaultsKey = "corvus.conversationMode"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .realtime: return "Realtime"
    case .turnBased: return "Turn based"
    }
  }

  func footer(engine: IntelligenceEngine) -> String {
    switch self {
    case .realtime:
      return engine == .openai
        ? "OpenAI gpt-realtime listens and speaks; interrupt it any time. Applies to the next mission."
        : "Google Gemini Live listens and speaks; interrupt it any time. Applies to the next mission."
    case .turnBased:
      return "Deepgram hears the answer, Gemini Flash picks the next question, ElevenLabs "
        + "says it: the same stack as pulseiq's interviews. About two seconds between "
        + "turns and no interrupting, but the study's question is asked word for word "
        + "and follow-ups stay close to its probes. Applies to the next mission."
    }
  }

  static var stored: ConversationMode {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(ConversationMode.init(rawValue:)) ?? .realtime
  }
}
