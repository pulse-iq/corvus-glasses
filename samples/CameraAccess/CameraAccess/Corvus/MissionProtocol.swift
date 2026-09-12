import Foundation

struct MissionEnvelope: Codable {
  var version = 1
  let missionId: String
  let segmentId: String
  var operationId = UUID().uuidString.lowercased()
  let type: String
  var interceptId: String?
  var sequence: Int?
  var payload: MissionPayload = .init()
}

struct MissionPayload: Codable {
  var interceptId: String?
  var interviews: [MissionPayload]?
  var cameraReady: Bool?
  var microphoneReady: Bool?
  /// On the heartbeat: whether the wearer wants "Hey Corvus" listened for.
  var wakeWord: Bool?
  var studyId: String?
  var itemId: String?
  var itemName: String?
  var openingQuestion: String?
  var instructions: String?
  var triggeredAtMs: Double?
  var primitive: String?
  var confidence: Double?
  var reason: String?
  var code: String?
  var sequence: Int?
  var eventOperationId: String?
  var phase: MissionPhase?
  var serverNowMs: Double?
  var startedAtMs: Double?
  var voiceReady: Bool?
  var recordingStatus: String?
  var recordingKey: String?
  var egressId: String?
  var recordingStartedAtMs: Double?
  var endedAtMs: Double?
  var endedBecause: String?
  var abortReason: String?
  var transcriptOverflow: Bool?
  var resultKey: String?
  var turns: [MissionTranscriptTurn]?
  /// The intercept as a topic, for the turn-based conversation mode.
  var topic: MissionTopic?
  /// Which conversation mode the worker ran; echoed back on the record.
  var conversation: String?
  /// `wake` for an intercept the worker started because the wearer said
  /// "Hey Corvus"; absent for the phone's vision-triggered ones.
  var kind: String?
  var wakeUtterance: String?
  var wakeRequest: String?
}
/// One intercept in pulseiq-live-kit's terms: an opening question asked word
/// for word, probe questions as a guide, a hard cap on follow-ups, and context
/// the model may steer by but never speak.
struct MissionTopic: Codable, Equatable {
  var question: String
  var probeQuestions: [String]
  var probeDepth: Int
  var context: String?
}
struct MissionTranscriptTurn: Codable, Equatable {
  let role: String
  let text: String
  let atMs: Double
}
