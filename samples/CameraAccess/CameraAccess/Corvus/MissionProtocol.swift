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
  var deadlineMs: Double?
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
}
struct MissionTranscriptTurn: Codable, Equatable {
  let role: String
  let text: String
  let atMs: Double
}
