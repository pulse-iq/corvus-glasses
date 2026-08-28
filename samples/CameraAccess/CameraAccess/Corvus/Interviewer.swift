import Foundation

/// One question asked and whatever came back.
struct InterviewTurn: Codable, Identifiable, Equatable {
  var id: String = UUID().uuidString
  let question: String
  var askedAt: Date
  /// Relative to the session directory, so a log folder stays portable.
  var audioPath: String?
  var transcript: String?
  var transcriptError: String?
  var answerSeconds: Double?
  /// Loudest and quietest levels seen while recording, in dBFS. Kept because
  /// the silence threshold is guesswork until there is field audio to tune it
  /// against, and these are the numbers that tune it.
  var peakDB: Double?
  var averageDB: Double?
  /// Loudest instantaneous level heard, which the relative silence threshold is
  /// measured down from. The number to look at when an answer gets clipped.
  var loudestDB: Double?
  /// The recorder's own level readings, one per 100 ms. Ground truth for
  /// tuning the silence threshold -- and the only measurement of it that has
  /// not already misled us once.
  var meterTrace: [Double]?
  /// How long the model took to transcribe this answer and choose the next
  /// question. This is the silence the wearer actually experiences.
  var brainLatencyMS: Int?
  /// Why the model asked what it asked next, or chose to stop. Never spoken.
  var brainRationale: String?
  /// The question after this one was a rephrasing, because this answer was a
  /// request to repeat rather than an answer.
  var wasReask: Bool?
  /// Why recording stopped: silence, ceiling, or a failure.
  var endedBecause: String?
}

/// A complete intercept: what fired it, what was asked, what was said.
struct InterviewRecord: Codable, Identifiable, Equatable {
  var id: String = UUID().uuidString
  let studyID: String
  let itemID: String
  let itemName: String
  let triggeredAt: Date
  let confidence: Double
  var turns: [InterviewTurn] = []
  var endedAt: Date?
  /// Set when the interview did not complete normally.
  var abortReason: String?
  /// How a normally-completed interview ended: the model's own reason, or the
  /// turn limit. Distinct from `abortReason`, which means something went wrong.
  var endedBecause: String?
  var interviewer: String?
  var brain: String?
  /// Substantive questions asked, opener included. Re-asks excluded, which is
  /// why this is not just `turns.count`.
  var questionsAsked: Int?
  var reasks: Int?
  /// What the audio route actually resolved to, and whether it was the glasses.
  var routeMode: String?
  var routeInput: String?
  var routeOutput: String?
  var routeMatchedGlasses: Bool?

  var duration: TimeInterval? {
    endedAt.map { $0.timeIntervalSince(triggeredAt) }
  }
}

/// Stage 2. Takes a trigger and conducts the interview.
///
/// The whole point of the seam: `ScriptedInterviewer` speaks and records
/// locally today, and a `LiveKitInterviewer` running a realtime conversation
/// can replace it later without Stage 1, the study config, or the log format
/// noticing. Same shape as `ProductDetector`, for the same reason.
@MainActor
protocol Interviewer: AnyObject {
  var name: String { get }
  var isConfigured: Bool { get }

  /// Runs to completion, or returns a record carrying `abortReason`. It does
  /// not throw: an interview that half-happened is still data, and the watcher
  /// must be released either way.
  /// `frame` is the JPEG that fired the trigger, when one was kept. Passed so
  /// an interviewer can be concrete about the specific product in someone's
  /// hand rather than the category.
  func conduct(_ trigger: Trigger, study: Study, frame: Data?) async -> InterviewRecord

  /// Stop early -- the wearer took the glasses off, the study was switched.
  func cancel()
}

enum InterviewerKind: String, CaseIterable, Identifiable {
  /// Every question written in advance, in the study file. No model in the
  /// loop. Kept as the deterministic control: identical wording for every
  /// participant is sometimes exactly what a study wants.
  case scripted
  /// Study's opening question, then a model listens and chooses the follow-ups.
  case conversational
  /// Not built yet. Listed so the setting exists before the implementation
  /// does, and so choosing it fails loudly rather than silently doing nothing.
  case liveKit

  var id: String { rawValue }

  var label: String {
    switch self {
    case .scripted: return "Scripted (fixed questions)"
    case .conversational: return "Conversational (model picks follow-ups)"
    case .liveKit: return "LiveKit realtime (not built)"
    }
  }

  @MainActor
  func make() -> Interviewer? {
    switch self {
    case .scripted: return ScriptedInterviewer()
    case .conversational: return ConversationalInterviewer()
    case .liveKit: return nil
    }
  }
}
