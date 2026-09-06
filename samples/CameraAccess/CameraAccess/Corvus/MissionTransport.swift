import Foundation
import LiveKit

@MainActor
final class LiveKitMissionTransport {
  private let session: LiveKitSession
  var receive: ((MissionEnvelope) -> Void)?
  private var registered = false
  private var pending = Set<String>()
  private var replies: [String: MissionEnvelope] = [:]
  init(session: LiveKitSession) { self.session = session }
  func register() async throws {
    guard !registered else { return }
    try await session.room.registerTextStreamHandler(for: "corvus.mission.event") { [weak self] reader, identity in
      var text = ""
      for try await chunk in reader {
        text += chunk
        guard text.utf8.count <= 65_536 else { return }
      }
      guard let data = text.data(using: .utf8), let event = try? JSONDecoder().decode(MissionEnvelope.self, from: data), event.version == 1,
            UUID(uuidString: event.missionId) != nil, UUID(uuidString: event.segmentId) != nil, UUID(uuidString: event.operationId) != nil else { return }
      await self?.accept(event, sender: identity.stringValue)
    }
    registered = true
  }
  private func accept(_ event: MissionEnvelope, sender: String) {
    guard sender == session.missionWorkerIdentity else { return }
    if pending.contains(event.operationId), event.type == "accepted" || event.type == "rejected" { replies[event.operationId] = event }
    receive?(event)
  }
  func send(_ command: MissionEnvelope) async throws {
    let data = try JSONEncoder().encode(command)
    guard data.count <= 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
    _ = try await session.room.localParticipant.sendText(String(decoding: data, as: UTF8.self), options: StreamTextOptions(topic: "corvus.mission.command"))
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
