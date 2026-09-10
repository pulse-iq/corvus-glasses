import Foundation

@MainActor
final class LiveKitMissionTransport {
  private let media: any RealtimeMedia
  var receive: ((MissionEnvelope) -> Void)?
  private var registered = false
  private var pending = Set<String>()
  private var replies: [String: MissionEnvelope] = [:]
  init(media: any RealtimeMedia) { self.media = media }
  func register() async throws {
    guard !registered else { return }
    try await media.receiveText(topic: "corvus.mission.event", maxBytes: 65_536) { [weak self] text, identity in
      guard let data = text.data(using: .utf8), let event = try? JSONDecoder().decode(MissionEnvelope.self, from: data), event.version == 1,
            UUID(uuidString: event.missionId) != nil, UUID(uuidString: event.segmentId) != nil, UUID(uuidString: event.operationId) != nil else { return }
      await self?.accept(event, sender: identity)
    }
    registered = true
  }
  private func accept(_ event: MissionEnvelope, sender: String) {
    guard sender == media.workerIdentity else { return }
    if pending.contains(event.operationId), event.type == "accepted" || event.type == "rejected" { replies[event.operationId] = event }
    receive?(event)
  }
  func send(_ command: MissionEnvelope) async throws {
    let data = try JSONEncoder().encode(command)
    guard data.count <= 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
    try await media.sendText(String(decoding: data, as: UTF8.self), topic: "corvus.mission.command")
  }
  func request(_ command: MissionEnvelope) async throws -> MissionEnvelope {
    pending.insert(command.operationId)
    defer { replies.removeValue(forKey: command.operationId); pending.remove(command.operationId) }
    let start = ProcessInfo.processInfo.systemUptime
    var nextSend = 0
    let times: [Double] = [0, 1, 3, 7]
    while ProcessInfo.processInfo.systemUptime - start < 10 {
      try Task.checkCancellation()
      if let reply = replies[command.operationId] { return reply }
      if nextSend < times.count, ProcessInfo.processInfo.systemUptime - start >= times[nextSend] {
        try? await send(command)
        nextSend += 1
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw URLError(.timedOut)
  }
}
