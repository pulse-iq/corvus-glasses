import Foundation

/// An intercept over a realtime model, through the LiveKit room upstream already
/// builds and the worker in `agent/` already runs.
///
/// The reason this is a thin class rather than the large one it looks like it
/// should be: none of the hard parts are here. `LiveKitSession` already
/// publishes the microphone and the glasses feed into a room and already
/// receives live transcription of both sides; the Python worker already opens a
/// Gemini Live session. What was missing was only that a call began when the
/// app launched rather than when someone picked up a bottle, and that nobody
/// told the model it was conducting an intercept.
///
/// What this buys over `ConversationalInterceptor` is the four seconds between
/// someone finishing a sentence and hearing the next question. The model is
/// listening while they speak, so there is nothing to upload and nothing to
/// wait for. What it costs is a running worker and a room -- and the ability to
/// know, deterministically, what will be said, since the model now holds the
/// floor for the whole conversation rather than one question at a time.
@MainActor
final class LiveKitInterceptor: Interceptor {
  let name = "LiveKit realtime"

  private weak var session: LiveKitSession?
  private let log = CorvusLog.shared
  /// The agent's transcript, built from ordered conversation items on the
  /// worker rather than reassembled here from two independent caption streams.
  /// The phone deliberately keeps no reconstruction of its own: that version
  /// mis-paired questions with the wrong answers, and a plausible-looking wrong
  /// transcript is worse in research data than a missing one.
  private var agentTranscript: [(isAgent: Bool, text: String)]?
  /// Where the worker filed the room recording. Arrives on the same payload as
  /// the transcript because that is the only channel back from the worker, and
  /// there is no backend to ask afterwards.
  private var recordingKey: String?
  private var cancelled = false

  init(session: LiveKitSession?) {
    self.session = session
  }

  /// Needs a live session object and a gateway to mint room tokens. Both are
  /// external, so this is the one interceptor that can be selected and still
  /// be unable to run.
  var isConfigured: Bool { session != nil && GeminiConfig.isAgentConfigured }

  func cancel() {
    cancelled = true
  }

  func conduct(_ trigger: Trigger, study: Study, frame: Data?) async -> InterceptRecord {
    cancelled = false
    recordingKey = nil

    var record = InterceptRecord(
      studyID: study.id,
      itemID: trigger.item.id,
      itemName: trigger.item.displayName,
      triggeredAt: trigger.firedAt,
      confidence: trigger.confidence)
    record.interceptor = name
    record.brain = "realtime worker"

    guard let session else {
      record.abortReason = "No LiveKit session attached"
      return finish(record)
    }
    guard GeminiConfig.isAgentConfigured else {
      record.abortReason = "Gateway not configured — cannot mint a room token"
      return finish(record)
    }

    // Everything the worker needs for this one intercept. It reads participant
    // metadata already; these are extra keys in the same place.
    session.pendingSessionContext = [
      "mode": "intercept",
      "studyId": study.id,
      "itemId": trigger.item.id,
      "itemName": trigger.item.displayName,
      "openingQuestion": trigger.item.question,
      "instructions": InterceptPrompt.realtime(study: study, item: trigger.item),
      // The worker files the recording under this, so every intercept from one
      // run of the app lands beside the log directory it belongs to.
      "sessionId": log.sessionName,
    ]
    defer { session.pendingSessionContext = nil }

    // Both sides of the conversation arrive as transcription streams, so the
    // transcript is a by-product of the call rather than something to capture.
    // One callback per finished utterance -- the earlier version watched the
    // published caption and inferred boundaries from text prefixes, which
    // turned partial lines like "Thanks" into questions of their own.
    session.onTranscript = { [weak self] json in
      self?.absorbAgentTranscript(json)
    }
    defer { session.onTranscript = nil }

    await session.start()
    if case .failed(let why) = session.state {
      record.abortReason = why
      return finish(record)
    }
    // Read after the room is up, because publishing video is allowed to fail
    // without failing the call: "none" here is the signature of an intercept
    // that sounded perfect and recorded a black rectangle.
    record.videoSource = session.localVideoTrack == nil
      ? "none"
      : (session.usingGlassesSource ? "glasses" : "phone")

    let outcome = await waitForCompletion(session)
    record.endedBecause = outcome.reason
    record.abortReason = outcome.abort
    record.turns = turns()
    record.recordingKey = recordingKey
    // No transcript means the worker died before publishing one. Left empty
    // rather than approximated; abortReason says what happened.
    if agentTranscript == nil {
      NSLog("[Corvus] no transcript published by the worker")
    }

    await session.stop()
    return finish(record)
  }

  // MARK: - Waiting

  private struct Outcome {
    var reason: String?
    var abort: String?
  }

  /// The worker ends an intercept by leaving the room, so a departed agent is
  /// the normal finish. The ceilings exist because every other way this ends is
  /// a failure that would otherwise hold the watcher's lock open.
  private func waitForCompletion(_ session: LiveKitSession) async -> Outcome {
    let started = Date()
    let joinDeadline = CorvusConfig.agentJoinTimeoutSeconds
    let ceiling = CorvusConfig.maxRealtimeInterceptSeconds
    var everJoined = false

    while true {
      if cancelled { return Outcome(reason: nil, abort: "cancelled") }

      switch session.agentStatus {
      case .listening, .thinking, .speaking, .starting:
        everJoined = true
      case .left:
        // Only meaningful after it actually arrived; `left` is also the state
        // before anything has ever joined.
        if everJoined { return Outcome(reason: "worker ended the intercept") }
      case .waiting, .none:
        break
      }

      // The worker ends an intercept by deleting the room, which reaches the
      // phone as a disconnect carrying "Room deleted". Once it has joined,
      // any close is the intercept finishing; only a failure before it ever
      // arrived is an abort worth recording as one.
      if case .failed(let why) = session.state {
        return everJoined ? Outcome(reason: "room closed (\(why))") : Outcome(abort: why)
      }
      if session.state == .disconnected, everJoined {
        return Outcome(reason: "room closed")
      }

      let elapsed = Date().timeIntervalSince(started)
      if !everJoined, elapsed > joinDeadline {
        return Outcome(abort: "no worker joined the room within \(Int(joinDeadline))s")
      }
      if elapsed > ceiling {
        return Outcome(abort: "exceeded \(Int(ceiling))s ceiling")
      }

      try? await Task.sleep(nanoseconds: 250_000_000)
    }
  }

  // MARK: - Transcript

  private struct AgentTranscript: Decodable {
    struct Turn: Decodable { let role: String; let text: String }
    let turns: [Turn]
    /// Absent whenever the worker had no credentials to record with, which is
    /// a configuration state rather than a failure -- so it decodes as optional
    /// and the intercept carries on without it.
    let recordingKey: String?
  }

  private func absorbAgentTranscript(_ json: String) {
    guard let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(AgentTranscript.self, from: data)
    else {
      NSLog("[Corvus] could not decode agent transcript")
      return
    }
    agentTranscript = decoded.turns.map {
      (isAgent: $0.role == "assistant", text: $0.text)
    }
    recordingKey = decoded.recordingKey
    NSLog("[Corvus] agent transcript: %d item(s)%@", decoded.turns.count,
          decoded.recordingKey.map { ", recording \($0)" } ?? "")
  }

  /// Pair each thing the interceptor said with the answer that followed it.
  private func turns() -> [InterceptTurn] {
    var out: [InterceptTurn] = []
    var pending: String?
    // Whole and in order already; nothing to clean or re-sequence.
    for segment in agentTranscript ?? [] {
      if segment.isAgent {
        if let question = pending {
          out.append(InterceptTurn(question: question, askedAt: Date()))
        }
        pending = segment.text
      } else if let question = pending {
        var turn = InterceptTurn(question: question, askedAt: Date())
        turn.transcript = segment.text
        out.append(turn)
        pending = nil
      }
    }
    if let question = pending {
      out.append(InterceptTurn(question: question, askedAt: Date()))
    }
    return out
  }

  // MARK: - Persistence

  @discardableResult
  private func finish(_ record: InterceptRecord) -> InterceptRecord {
    var record = record
    record.endedAt = Date()
    record.questionsAsked = record.turns.filter { !$0.question.isEmpty }.count

    let directory = log.sessionDirectory.appendingPathComponent("intercepts", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(record) {
      try? data.write(
        to: directory.appendingPathComponent("\(record.id).json"), options: .atomic)
    }

    log.append(.init(
      kind: "intercept",
      at: record.endedAt ?? Date(),
      itemID: record.itemID,
      confidence: record.confidence,
      error: record.abortReason,
      note: "realtime turns=\(record.turns.count) ended=\(record.endedBecause ?? "?")"))
    NSLog("[Corvus] realtime intercept %@: %d turn(s)%@",
          record.itemID, record.turns.count,
          record.abortReason.map { " aborted: \($0)" } ?? "")
    return record
  }
}
