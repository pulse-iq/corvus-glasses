import AVFoundation
import Foundation

/// An intercept with a model in the loop.
///
/// Same half-duplex mechanics as `ScriptedInterceptor` -- speak, listen, speak --
/// but every question after the opener is chosen by a model that has heard the
/// answers. The opener stays fixed on purpose: it is the study's own wording,
/// asked identically to every participant, which is what makes their answers
/// comparable. Improvising the opening question would trade the one piece of
/// experimental control this design has for nothing.
///
/// The cost of half duplex is unchanged and still real: roughly two seconds of
/// silence between someone finishing and the next question arriving, and no way
/// to interrupt. A realtime `Interceptor` fixes both; the intercepting
/// judgement it would need already lives in `InterceptPrompt` and moves across
/// untouched.
@MainActor
final class ConversationalInterceptor: Interceptor {
  let name = "Conversational"

  private let speaker = SpeechPlayer()
  private let recorder = AnswerRecorder()
  private let brain: InterceptBrain = GeminiInterceptBrain()
  private let log = CorvusLog.shared
  private var cancelled = false

  var isConfigured: Bool { brain.isConfigured }

  func cancel() {
    cancelled = true
    speaker.stop()
    recorder.cancel()
  }

  func conduct(_ trigger: Trigger, study: Study, frame: Data?) async -> InterceptRecord {
    cancelled = false
    var record = InterceptRecord(
      studyID: study.id,
      itemID: trigger.subject.targetID,
      itemName: trigger.subject.displayName,
      triggeredAt: trigger.firedAt,
      confidence: trigger.confidence)
    record.interceptor = name
    record.primitive = trigger.primitive.rawValue
    record.brain = brain.name

    do {
      let activation = try GlassesAudioSession.activate(mode: CorvusConfig.audioRouteMode)
      record.routeMode = activation.mode.rawValue
      record.routeInput = activation.inputName
      record.routeOutput = activation.outputName
      record.routeMatchedGlasses = activation.matchedGlasses
    } catch {
      record.abortReason = error.localizedDescription
      record.endedAt = Date()
      persist(record)
      return record
    }
    defer { GlassesAudioSession.deactivate() }

    try? await Task.sleep(nanoseconds: 400_000_000)

    var history: [BrainTurn] = []
    var question = trigger.subject.question
    let maxTurns = max(1, CorvusConfig.maxInterceptTurns)
    let maxReasks = max(0, CorvusConfig.maxReasks)

    // Substantive questions asked, starting with the study's opener. Re-asks
    // are tracked apart: someone who did not catch the question has not spent a
    // turn of their intercept, and charging them one is how you end up with a
    // single-question transcript that says "Looking at what?".
    var asked = 1
    var reasks = 0
    var index = 0

    while true {
      if cancelled { record.abortReason = "cancelled"; break }

      var turn = InterceptTurn(question: question, askedAt: Date())
      await speaker.say(question)
      if cancelled {
        turn.endedBecause = "cancelled"
        record.turns.append(turn)
        record.abortReason = "cancelled"
        break
      }

      let filename = "intercept-\(record.id)-\(index).wav"
      let url = log.sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        .appendingPathComponent(filename)
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

      let answer: AnswerRecorder.Result
      do {
        answer = try await recorder.record(to: url, wav: true)
      } catch {
        turn.endedBecause = "error"
        turn.transcriptError = error.localizedDescription
        record.turns.append(turn)
        record.abortReason = error.localizedDescription
        break
      }
      turn.audioPath = "audio/\(filename)"
      turn.answerSeconds = answer.seconds
      turn.peakDB = answer.peakDB
      turn.loudestDB = answer.loudestDB
      turn.meterTrace = answer.meterTrace
      turn.averageDB = answer.averageDB
      turn.endedBecause = answer.endedBecause

      index += 1
      let questionsLeft = maxTurns - asked

      // Nothing left to ask and no re-ask allowance: stop before paying for a
      // decision that cannot be acted on.
      guard (questionsLeft > 0 || reasks < maxReasks), !cancelled else {
        record.turns.append(turn)
        if record.endedBecause == nil { record.endedBecause = "turn limit" }
        break
      }

      do {
        let audio = try Data(contentsOf: url)
        let decision = try await brain.decide(
          study: study,
          subject: trigger.subject,
          currentQuestion: question,
          history: history,
          answerAudio: audio,
          answerMimeType: "audio/wav",
          triggerFrame: frame,
          turnsRemaining: max(0, questionsLeft))

        turn.transcript = decision.transcript
        turn.brainLatencyMS = Int(decision.latency * 1000)
        turn.brainRationale = decision.rationale
        turn.wasReask = decision.isReask
        record.turns.append(turn)
        history.append(BrainTurn(question: question, answerTranscript: decision.transcript))

        guard let next = decision.nextQuestion, !cancelled else {
          record.endedBecause = decision.rationale ?? "model chose to stop"
          break
        }

        if decision.isReask {
          guard reasks < maxReasks else {
            // Repeating a third time is its own kind of pushing.
            record.endedBecause = "asked to repeat too many times"
            break
          }
          reasks += 1
        } else {
          guard questionsLeft > 0 else {
            record.endedBecause = "turn limit"
            break
          }
          asked += 1
        }
        question = next
      } catch {
        // A failed turn ends the intercept rather than retrying: the wearer is
        // standing there in silence, and a second round trip is a worse
        // experience than a short intercept.
        turn.transcriptError = error.localizedDescription
        record.turns.append(turn)
        record.abortReason = error.localizedDescription
        NSLog("[Corvus] brain failed: %@", error.localizedDescription)
        break
      }
    }

    if record.endedBecause == nil && record.abortReason == nil {
      record.endedBecause = "turn limit"
    }
    record.questionsAsked = asked
    record.reasks = reasks
    record.endedAt = Date()
    persist(record)
    return record
  }

  private func persist(_ record: InterceptRecord) {
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
      note: "turns=\(record.turns.count) ended=\(record.endedBecause ?? "?") "
        + "glasses=\(record.routeMatchedGlasses.map(String.init) ?? "?")"))

    for turn in record.turns where turn.transcript?.isEmpty == false {
      NSLog("[Corvus] Q: %@\n[Corvus] A: %@", turn.question, turn.transcript ?? "")
    }
  }
}
