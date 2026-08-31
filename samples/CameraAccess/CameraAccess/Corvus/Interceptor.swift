import Foundation

/// One question asked and whatever came back.
struct InterceptTurn: Codable, Identifiable, Equatable {
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
struct InterceptRecord: Codable, Identifiable, Equatable {
  var id: String = UUID().uuidString
  let studyID: String
  let itemID: String
  let itemName: String
  let triggeredAt: Date
  let confidence: Double
  var turns: [InterceptTurn] = []
  var endedAt: Date?
  /// Set when the intercept did not complete normally.
  var abortReason: String?
  /// How a normally-completed intercept ended: the model's own reason, or the
  /// turn limit. Distinct from `abortReason`, which means something went wrong.
  var endedBecause: String?
  var interceptor: String?
  var brain: String?
  /// Which primitive earned this intercept. The same product picked up and
  /// read up close are different moments and want to be countable apart, and
  /// once the question has been asked nothing else in the record says which.
  var primitive: String?
  /// Substantive questions asked, opener included. Re-asks excluded, which is
  /// why this is not just `turns.count`.
  var questionsAsked: Int?
  var reasks: Int?
  /// What the audio route actually resolved to, and whether it was the glasses.
  var routeMode: String?
  var routeInput: String?
  var routeOutput: String?
  var routeMatchedGlasses: Bool?
  /// What the room actually published as video, on the routes that publish
  /// any. The audio route is already recorded here because a silently wrong
  /// microphone once cost a session; video earns the same treatment for the
  /// same reason, and a recording that came out black says so here rather
  /// than only in the file.
  var videoSource: String?
  /// Object key of the room recording, on the routes that produce one. The
  /// bucket is not addressable from the phone, so this is a pointer rather
  /// than a path: it is how a record found in `intercepts/` names its video.
  var recordingKey: String?

  var duration: TimeInterval? {
    endedAt.map { $0.timeIntervalSince(triggeredAt) }
  }
}

/// Takes a trigger and conducts the intercept.
///
/// The whole point of the seam: `ScriptedInterceptor` speaks and records
/// locally today, and a `LiveKitInterceptor` running a realtime conversation
/// can replace it later without the watcher, the study config, or the log format
/// noticing. Same shape as `ProductDetector`, for the same reason.
@MainActor
protocol Interceptor: AnyObject {
  var name: String { get }
  var isConfigured: Bool { get }

  /// Runs to completion, or returns a record carrying `abortReason`. It does
  /// not throw: an intercept that half-happened is still data, and the watcher
  /// must be released either way.
  /// `frame` is the JPEG that fired the trigger, when one was kept. Passed so
  /// an interceptor can be concrete about the specific product in someone's
  /// hand rather than the category.
  func conduct(_ trigger: Trigger, study: Study, frame: Data?) async -> InterceptRecord

  /// Stop early -- the wearer took the glasses off, the study was switched.
  func cancel()
}

enum InterceptorKind: String, CaseIterable, Identifiable {
  /// Every question written in advance, in the study file. No model in the
  /// loop. Kept as the deterministic control: identical wording for every
  /// participant is sometimes exactly what a study wants.
  case scripted
  /// Study's opening question, then a model listens and chooses the follow-ups.
  case conversational
  /// Realtime, through the LiveKit room and the worker in `agent/`. Needs a
  /// live session object and a gateway that can mint room tokens, so unlike the
  /// others it can be selected while unable to run -- which it reports rather
  /// than failing silently.
  case liveKit

  var id: String { rawValue }

  var label: String {
    switch self {
    case .scripted: return "Scripted (fixed questions)"
    case .conversational: return "Conversational (model picks follow-ups)"
    case .liveKit: return "Realtime (LiveKit + Gemini Live)"
    }
  }

  @MainActor
  func make(liveKit: LiveKitSession? = nil) -> Interceptor? {
    switch self {
    case .scripted: return ScriptedInterceptor()
    case .conversational: return ConversationalInterceptor()
    case .liveKit: return LiveKitInterceptor(session: liveKit)
    }
  }
}
