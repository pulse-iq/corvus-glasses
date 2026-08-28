import AVFoundation
import Foundation

/// Stage 2, half-duplex: ask, listen, ask the follow-ups, write it down.
///
/// It never listens while it speaks, which is what lets it skip the whole
/// realtime-audio apparatus -- no echo cancellation, no barge-in, no streaming
/// session to keep alive. The cost is real and worth naming: someone who starts
/// answering before the question ends is not heard until the recorder opens,
/// and there is no way to interrupt Corvus mid-sentence. That trade is fine for
/// one question and a couple of follow-ups; it is the reason a realtime
/// `Interviewer` will eventually replace this one.
@MainActor
final class ScriptedInterviewer: Interviewer {
  let name = "Scripted"

  private let speaker = SpeechPlayer()
  private let recorder = AnswerRecorder()
  private let transcriber: Transcriber = OpenAITranscriber()
  private let log = CorvusLog.shared
  private var cancelled = false

  /// Speaking always works; transcription is the part that needs a key, and it
  /// happens after the fact, so a missing key degrades rather than blocks.
  var isConfigured: Bool { true }

  func cancel() {
    cancelled = true
    speaker.stop()
    recorder.cancel()
  }

  func conduct(_ trigger: Trigger, study: Study, frame: Data?) async -> InterviewRecord {
    cancelled = false
    var record = InterviewRecord(
      studyID: study.id,
      itemID: trigger.item.id,
      itemName: trigger.item.displayName,
      triggeredAt: trigger.firedAt,
      confidence: trigger.confidence)
    record.interviewer = name

    // Take the route first: a failure here means the wearer would be recorded
    // without ever hearing a question, which is worse than not starting.
    do {
      let activation = try GlassesAudioSession.activate(mode: CorvusConfig.audioRouteMode)
      record.routeMode = activation.mode.rawValue
      record.routeInput = activation.inputName
      record.routeOutput = activation.outputName
      record.routeMatchedGlasses = activation.matchedGlasses
      if !activation.matchedGlasses {
        NSLog("[Corvus] interview audio is NOT on the glasses: in=%@ out=%@",
              activation.inputName, activation.outputName)
      }
    } catch {
      record.abortReason = error.localizedDescription
      record.endedAt = Date()
      finish(record)
      return record
    }
    defer { GlassesAudioSession.deactivate() }

    // A short lead-in stops the first syllable being clipped by the Bluetooth
    // route still settling, and gives the wearer a beat to register that
    // something is about to speak to them.
    try? await Task.sleep(nanoseconds: 400_000_000)

    let questions = [trigger.item.question] + trigger.item.followUps
    for (index, question) in questions.enumerated() {
      if cancelled {
        record.abortReason = "cancelled"
        break
      }
      var turn = InterviewTurn(question: question, askedAt: Date())
      await speaker.say(question)
      if cancelled {
        turn.endedBecause = "cancelled"
        record.turns.append(turn)
        record.abortReason = "cancelled"
        break
      }

      let filename = "interview-\(record.id)-\(index).m4a"
      let url = log.sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        .appendingPathComponent(filename)
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

      do {
        let result = try await recorder.record(to: url)
        turn.audioPath = "audio/\(filename)"
        turn.answerSeconds = result.seconds
        turn.peakDB = result.peakDB
        turn.loudestDB = result.loudestDB
        turn.meterTrace = result.meterTrace
        turn.averageDB = result.averageDB
        turn.endedBecause = result.endedBecause
      } catch {
        turn.endedBecause = "error"
        turn.transcriptError = error.localizedDescription
        record.turns.append(turn)
        record.abortReason = error.localizedDescription
        break
      }

      record.turns.append(turn)
    }

    record.endedAt = Date()
    finish(record)

    // Transcribe off the interview's own timeline. The watcher is released the
    // moment this returns, so the wearer is never waiting on an API call.
    if CorvusConfig.transcribeAnswers {
      let snapshot = record
      Task { await self.transcribe(snapshot) }
    }

    return record
  }

  // MARK: - Persistence

  private func finish(_ record: InterviewRecord) {
    write(record)
    log.append(.init(
      kind: "interview",
      at: record.endedAt ?? Date(),
      itemID: record.itemID,
      confidence: record.confidence,
      error: record.abortReason,
      note: "turns=\(record.turns.count) route=\(record.routeOutput ?? "?") "
        + "glasses=\(record.routeMatchedGlasses.map(String.init) ?? "?")"))
    NSLog("[Corvus] interview %@ finished: %d turn(s)%@",
          record.itemID, record.turns.count,
          record.abortReason.map { " aborted: \($0)" } ?? "")
  }

  /// One file per interview, rewritten as transcripts land. Separate from the
  /// event log because this is the deliverable -- the thing someone reads --
  /// rather than a trace of what the app did.
  private func write(_ record: InterviewRecord) {
    let directory = log.sessionDirectory.appendingPathComponent("interviews", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(record) else { return }
    try? data.write(
      to: directory.appendingPathComponent("\(record.id).json"), options: .atomic)
  }

  private func transcribe(_ record: InterviewRecord) async {
    guard transcriber.isConfigured else {
      NSLog("[Corvus] no OpenAI key; audio kept, transcripts skipped")
      return
    }
    var updated = record
    for (index, turn) in record.turns.enumerated() {
      guard let path = turn.audioPath else { continue }
      let url = log.sessionDirectory.appendingPathComponent(path)
      do {
        updated.turns[index].transcript = try await transcriber.transcribe(url)
      } catch {
        updated.turns[index].transcriptError = error.localizedDescription
        NSLog("[Corvus] transcription failed: %@", error.localizedDescription)
      }
      write(updated)
    }
  }
}
