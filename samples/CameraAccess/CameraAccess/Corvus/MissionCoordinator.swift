import Combine
import Foundation

@MainActor
final class MissionCoordinator: ObservableObject, Interceptor {
  /// Injectable media boundary keeps cancellation tests independent of cameras and the network.
  struct MediaOperations {
    let connect: () async -> Void
    let stopCapture: () async -> Void
    let disconnect: () async -> Void
    let endOnGateway: () async -> Void
  }
  private let media: MediaOperations?
  init(media: MediaOperations? = nil) { self.media = media }
  let name = "Mission realtime"
  var isConfigured: Bool { GeminiConfig.isAgentConfigured }
  @Published private(set) var lifecycle = MissionState()
  @Published private(set) var recordingStatus: String?
  @Published private(set) var errorMessage: String?
  var isActive: Bool { lifecycle.phase != .idle && lifecycle.phase != .ended }
  private var session: (any RealtimeMedia)?
  private var transport: LiveKitMissionTransport?
  private weak var watcher: WatcherCoordinator?
  private var stopDAT: (() async -> Void)?
  private var missionID = UUID().uuidString.lowercased()
  private var segmentID = UUID().uuidString.lowercased()
  private var heartbeat: Task<Void, Never>?
  private var startTask: Task<Void, Never>?
  private var results: [String: InterceptRecord] = [:]
  private var activeIntercept: String?
  private var fetchingResults = Set<String>()
  private var events: [MissionEnvelope] = []
  private var latestSequence = 0
  private var serverShopping = false
  private var setupUptime = 0.0
  private var lostReadinessAt: Double?

  func attach(session: any RealtimeMedia, watcher: WatcherCoordinator, stopDAT: @escaping () async -> Void) {
    guard self.session == nil else { return }
    self.session = session
    self.watcher = watcher
    self.stopDAT = stopDAT
    let transport = LiveKitMissionTransport(media: session)
    self.transport = transport
    transport.receive = { [weak self] event in self?.receive(event) }
    watcher.setMissionReady(false)
  }

  func start(study: Study, source: CaptureSource, engine: IntelligenceEngine, startDAT: @escaping () async -> Void) {
    guard !isActive, let session, let transport, let watcher else { return }
    let generation = lifecycle.begin()
    missionID = UUID().uuidString.lowercased(); segmentID = UUID().uuidString.lowercased()
    events = []; results = [:]; activeIntercept = nil; fetchingResults = []; latestSequence = 0; serverShopping = false
    recordingStatus = nil; errorMessage = nil; lostReadinessAt = nil
    setupUptime = ProcessInfo.processInfo.systemUptime
    watcher.use(study); watcher.interceptor = self; watcher.setMissionReady(false); watcher.start()
    session.callContext = RealtimeCallContext(
      metadata: ["mode": "mission", "version": "1", "missionId": missionID,
        "segmentId": segmentID, "studyId": study.id, "sessionId": CorvusLog.shared.sessionName,
        "conversation": ConversationMode.stored.rawValue],
      source: source, engine: engine)
    do { try persist() } catch {
      errorMessage = error.localizedDescription
      Task { await self.end(reason: "persistence_failed") }; return
    }
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        await self?.tick(generation: generation)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
    startTask = Task { [weak self] in
      do {
        if self?.media == nil { try await transport.register() }
        guard let self, generation == self.lifecycle.generation, !Task.isCancelled else { return }
        if source == .glasses { await startDAT() }
        guard generation == self.lifecycle.generation, !Task.isCancelled else { await self.stopDAT?(); return }
        if let media = self.media { await media.connect() } else { await session.connect() }
        guard generation == self.lifecycle.generation, !Task.isCancelled else {
          if let media = self.media { await media.disconnect() } else { await session.disconnect(restartPreview: false) }
          return
        }
        if case .failed(let why) = session.linkState { self.errorMessage = why; Task { await self.end(reason: "setup_failed") } }
      } catch { self?.errorMessage = error.localizedDescription; Task { await self?.end(reason: "setup_failed") } }
    }
  }

  private func tick(generation: Int) async {
    guard generation == lifecycle.generation, let session else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if !lifecycle.started, now - setupUptime >= 45 {
      errorMessage = "Mission setup timed out. Check camera, agent, and recording availability."
      await end(reason: "setup_timeout"); return
    }
    let ready = session.linkState == .connected && session.isTransportConnected && session.agentPresence != .left && session.hasFreshFrame && session.videoSource != nil
    watcher?.setMissionReady(ready && serverShopping && recordingStatus == "recording")
    if !ready, lifecycle.started {
      serverShopping = false
      lifecycle.apply(phase: .reconnecting, generation: generation)
      lostReadinessAt = lostReadinessAt ?? now
      if now - (lostReadinessAt ?? now) >= 20 { errorMessage = "Mission connection could not recover."; await end(reason: "readiness_timeout"); return }
    } else if ready, lostReadinessAt != nil {
      lostReadinessAt = nil
      try? await transport?.send(command("sync"))
    }
    guard generation == lifecycle.generation, !Task.isCancelled else { return }
    if ready, let image = session.latestFrame { watcher?.submit(image: image) }
    var payload = MissionPayload(); payload.cameraReady = ready; payload.microphoneReady = ready
    try? await transport?.send(command("client_ready", payload: payload))
  }

  private func command(_ type: String, intercept: String? = nil, payload: MissionPayload = .init()) -> MissionEnvelope {
    MissionEnvelope(missionId: missionID, segmentId: segmentID, type: type, interceptId: intercept, payload: payload)
  }

  private func receive(_ event: MissionEnvelope) {
    guard event.missionId == missionID, event.segmentId == segmentID else { return }
    if event.type == "accepted" || event.type == "rejected" { return }
    if event.payload.transcriptOverflow == true, let id = event.interceptId {
      guard fetchingResults.insert(id).inserted else { return }
      Task {
        defer { if missionID == event.missionId { fetchingResults.remove(id) } }
        do {
          let data = try await gatewayStatus(missionID: event.missionId, interceptID: id)
          var full = event
          full.payload = try JSONDecoder().decode(MissionPayload.self, from: data)
          full.payload.transcriptOverflow = false
          receive(full)
        } catch {
          guard missionID == event.missionId else { return }
          errorMessage = "Interview is saved on the server; download could not finish."
          watcher?.setMissionReady(false)
        }
      }
      return
    }
    let duplicate = events.contains { $0.operationId == event.operationId && $0.type == event.type }
    if !duplicate {
      events.append(event)
      if event.type == "intercept_completed", let id = event.interceptId {
        let p = event.payload
        var record = results[id] ?? InterceptRecord(id: id, studyID: p.studyId ?? "unknown", itemID: p.itemId ?? "unknown", itemName: p.itemName ?? "unknown", triggeredAt: Date(timeIntervalSince1970: (p.triggeredAtMs ?? 0) / 1000), confidence: p.confidence ?? 0)
        record.endedAt = p.endedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        record.endedBecause = p.endedBecause; record.abortReason = p.abortReason
        record.missionID = missionID; record.segmentID = segmentID; record.recordingKey = p.recordingKey
        record.authoritativeTurns = p.turns
        record.recordingOffsetSeconds = p.recordingStartedAtMs.map { record.triggeredAt.timeIntervalSince1970 - $0 / 1000 }
        var turns: [InterceptTurn] = []
        for utterance in p.turns ?? [] {
          if utterance.role == "assistant" { turns.append(InterceptTurn(question: utterance.text, askedAt: Date(timeIntervalSince1970: utterance.atMs / 1000))) }
          else if !turns.isEmpty { turns[turns.count - 1].transcript = [turns.last?.transcript, utterance.text].compactMap { $0 }.joined(separator: "\n") }
        }
        record.turns = turns; results[id] = record
      }
    }
    do { try persist() } catch {
      errorMessage = "Could not save mission: \(error.localizedDescription)"
      watcher?.setMissionReady(false)
      Task { await self.end(reason: "persistence_failed") }; return
    }
    let sequence = event.sequence ?? event.payload.sequence ?? 0
    if sequence >= latestSequence, isActive, lifecycle.phase != .ending {
      latestSequence = sequence
      let p = event.payload
      if let status = p.recordingStatus { recordingStatus = status }
      if let phase = p.phase {
        lifecycle.apply(phase: phase == .ended ? .reconnecting : phase, generation: lifecycle.generation)
        serverShopping = phase == .shopping && p.voiceReady == true && recordingStatus == "recording"
        watcher?.setMissionReady(serverShopping && session?.hasFreshFrame == true)
      }
      if event.type == "mission_ended" || p.phase == .ended {
        // Terminal state still needs local media cleanup.
        lifecycle.apply(phase: .reconnecting, generation: lifecycle.generation)
        Task { await self.end(reason: p.endedBecause ?? p.reason ?? "server_ended") }
      }
    }
    var ack = MissionPayload(); ack.sequence = sequence; ack.eventOperationId = event.operationId
    let message = command("ack", payload: ack)
    Task { try? await transport?.send(message) }
  }

  private func persist() throws {
    let root = CorvusLog.shared.sessionDirectory
    let directory = root.appendingPathComponent("missions/\(missionID)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    for record in results.values {
      let interviews = root.appendingPathComponent("intercepts", isDirectory: true)
      try FileManager.default.createDirectory(at: interviews, withIntermediateDirectories: true)
      try encoder.encode(record).write(to: interviews.appendingPathComponent("\(record.id).json"), options: .atomic)
    }
    struct Manifest: Encodable { let missionId: String; let segmentId: String; let phase: MissionPhase; let events: [MissionEnvelope]; let interviews: [String] }
    try encoder.encode(Manifest(missionId: missionID, segmentId: segmentID, phase: lifecycle.phase, events: events, interviews: Array(results.keys))).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
  }

  func conduct(_ trigger: Trigger, study: Study, frame: Data?) async -> InterceptRecord {
    var record = InterceptRecord(studyID: study.id, itemID: trigger.subject.targetID, itemName: trigger.subject.displayName, triggeredAt: trigger.firedAt, confidence: trigger.confidence)
    record.missionID = missionID; record.segmentID = segmentID; record.primitive = trigger.primitive.rawValue; record.interceptor = name
    guard serverShopping, activeIntercept == nil, let transport else { record.abortReason = "mission_not_ready"; return record }
    let generation = lifecycle.generation
    record.id = record.id.lowercased()
    let id = record.id; activeIntercept = id; results[id] = record
    defer { if generation == lifecycle.generation, activeIntercept == id { activeIntercept = nil } }
    var brief = MissionPayload(); brief.studyId = study.id; brief.itemId = record.itemID; brief.itemName = record.itemName
    brief.openingQuestion = trigger.subject.question; brief.instructions = InterceptPrompt.realtime(study: study, subject: trigger.subject)
    brief.topic = InterceptPrompt.topic(study: study, subject: trigger.subject)
    brief.triggeredAtMs = trigger.firedAt.timeIntervalSince1970 * 1000; brief.primitive = trigger.primitive.rawValue; brief.confidence = trigger.confidence
    do {
      let reply = try await transport.request(command("begin_intercept", intercept: id, payload: brief))
      guard generation == lifecycle.generation else { record.abortReason = "mission_ended"; return record }
      guard reply.type == "accepted" else { record.abortReason = reply.payload.code ?? reply.payload.reason ?? "rejected"; results[id] = record; try persist(); return record }
      let began = ProcessInfo.processInfo.systemUptime
      while generation == lifecycle.generation && !Task.isCancelled {
        if let result = results[id], result.endedAt != nil { return result }
        if ProcessInfo.processInfo.systemUptime - began > CorvusConfig.maxRealtimeInterceptSeconds { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      record = results[id] ?? record; record.abortReason = "interrupted"
    } catch {
      guard generation == lifecycle.generation else { record.abortReason = "mission_ended"; return record }
      try? await transport.send(command("sync"))
      record.abortReason = error.localizedDescription
    }
    guard generation == lifecycle.generation else { record.abortReason = "mission_ended"; return record }
    var cancellation = MissionPayload(); cancellation.reason = "client_interrupted"
    try? await transport.send(command("cancel_intercept", intercept: id, payload: cancellation))
    record.endedAt = Date(); results[id] = record; try? persist()
    return record
  }
  func cancel() {
    guard let activeIntercept, lifecycle.phase != .ending else { return }
    let message = command("cancel_intercept", intercept: activeIntercept)
    Task { try? await transport?.send(message) }
  }
  private func gatewayStatus(missionID: String, interceptID: String? = nil) async throws -> Data {
    var components = URLComponents(string: "\(GeminiConfig.agentBaseURL)/mission-status")!
    components.queryItems = [URLQueryItem(name: "missionId", value: missionID)]
    if let interceptID { components.queryItems?.append(URLQueryItem(name: "interceptId", value: interceptID)) }
    var request = URLRequest(url: components.url!); request.timeoutInterval = 5
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
  }

  private func endOnGateway(missionID: String, reason: String) async {
    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/mission-end") else { return }
    var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 3
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["missionId": missionID, "reason": reason])
    _ = try? await URLSession.shared.data(for: request)
  }

  func end(reason: String = "user_ended") async {
    guard lifecycle.phase != .ending, lifecycle.phase != .idle, lifecycle.phase != .ended else { return }
    lifecycle.end(); serverShopping = false
    for id in results.keys where results[id]?.endedAt == nil {
      results[id]?.endedAt = Date()
      results[id]?.abortReason = reason
    }
    heartbeat?.cancel(); startTask?.cancel(); watcher?.setMissionReady(false); watcher?.stop()
    // Stop source/publication before the network request, with no preview restart.
    if let media { await media.stopCapture() } else { await session?.stopCapture() }
    await stopDAT?()
    var payload = MissionPayload(); payload.reason = reason
    let message = command("end_mission", payload: payload)
    // Each send uses the same operation ID. Worker finalization persists after disconnect.
    if let media { await media.endOnGateway() } else {
      Task { try? await transport?.send(message) }
      await endOnGateway(missionID: missionID, reason: reason)
    }
    if let media { await media.disconnect() } else { await session?.disconnect(restartPreview: false) }
    await startTask?.value
    session?.callContext = nil
    lifecycle.finishedEnding()
    let endedMission = missionID
    guard media == nil else { try? persist(); return }
    Task { [weak self] in
      for _ in 0..<15 {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let self, self.missionID == endedMission else { return }
        if let data = try? await self.gatewayStatus(missionID: endedMission),
           let payload = try? JSONDecoder().decode(MissionPayload.self, from: data) {
          guard self.missionID == endedMission else { return }
          self.recordingStatus = payload.recordingStatus
          for interview in payload.interviews ?? [] {
            if let id = interview.interceptId, self.results[id]?.authoritativeTurns == nil {
              self.receive(self.command("intercept_completed", intercept: id, payload: interview))
            }
          }
          self.events.append(self.command("recording", payload: payload))
          try? self.persist()
          if payload.recordingStatus == "saved" || payload.recordingStatus == "failed" { return }
        }
      }
    }
    events.append(command("local_ended", payload: payload))
    do { try persist() } catch { errorMessage = error.localizedDescription }
  }
}
