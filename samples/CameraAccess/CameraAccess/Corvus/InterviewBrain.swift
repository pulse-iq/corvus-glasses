import Foundation

/// One exchange, as the brain sees it.
struct BrainTurn {
  let question: String
  let answerTranscript: String?
}

/// What the model decided to do next.
struct BrainDecision {
  /// Transcript of the answer it was just given. Comes back in the same call
  /// that chooses the next question, so the interview never waits on a separate
  /// transcription round trip.
  let transcript: String
  /// nil ends the interview.
  let nextQuestion: String?
  /// The question was not heard or not understood, and this is the same
  /// question said differently. Does not spend the interview's budget: being
  /// asked to repeat yourself is not a turn of the interview.
  let isReask: Bool
  /// Why it chose to continue or stop. Logged, never spoken -- during tuning
  /// "they already answered that" and "they sound impatient" call for different
  /// prompt fixes and are indistinguishable from the question alone.
  let rationale: String?
  let latency: TimeInterval
  let rawResponse: String
}

/// Decides what to ask next.
///
/// Separate from `Interviewer` on purpose: the interviewer owns audio, turns
/// and files, this owns judgement. Swapping to a realtime model later replaces
/// the interviewer and the transport, but the interviewing *behaviour* -- what
/// makes a good probe, when to stop -- is this prompt, and it carries over
/// unchanged. That is the part worth getting right now.
protocol InterviewBrain: Sendable {
  var name: String { get }
  var isConfigured: Bool { get }

  func decide(
    study: Study,
    item: WatchItem,
    currentQuestion: String,
    history: [BrainTurn],
    answerAudio: Data,
    answerMimeType: String,
    triggerFrame: Data?,
    turnsRemaining: Int
  ) async throws -> BrainDecision
}

/// The interviewing instructions.
///
/// Held in one place, like `DetectionPrompt`, because this is the actual
/// research instrument -- the difference between a useful intercept and an
/// annoying one is entirely in this text, and it needs to be reviewable as
/// prose rather than hunted for inside a request body.
enum InterviewPrompt {
  static func system(study: Study, item: WatchItem, turnsRemaining: Int) -> String {
    let scene = study.setting
    let goal = study.researchGoal ?? """
      Understand what drove this person's attention and choice at the shelf, in \
      their own words.
      """

    return """
    You are conducting a very short intercept interview. The person is wearing \
    camera glasses, is \(scene.wearer), and has just picked up \
    \(item.displayName). They have agreed to be interviewed while they go about \
    their day. You speak to them through their glasses; they answer out loud.

    What the researcher is trying to learn:
    \(goal)

    You will be given the audio of their most recent answer. Transcribe it, then \
    decide whether one more short question would tell the researcher something \
    they do not already have.

    How to ask:
    - One question at a time. Never stack two questions into one.
    - Under about fifteen words. They are standing up, holding a product.
    - Probe what they actually said, not the topic in general. If they mention \
    price, ask about price the way they framed it.
    - Ask for specifics: a moment, a comparison, a reason. Not a rating.
    - Never ask a yes/no question.
    - Plain spoken English. No preamble, no "thanks for sharing", no repeating \
    their answer back to them, no "that's interesting".
    - Never mention that you are an AI, a study, or a recording.

    If they did not hear you, or ask what you mean:
    - "What?", "Sorry?", "Looking at what?", "Huh?", "Say again" -- these are \
    NOT refusals. They are engaged and waiting for you to say it again.
    - Ask again, rephrased to be more concrete and self-contained. Do not repeat \
    the same words that already failed; say what you meant more plainly.
    - Set "is_reask": true for these. A re-ask does not count against your \
    question budget.
    - Never treat a request for clarification as a reason to stop.

    When to stop (return null for next_question):
    - They already gave a specific, complete answer and a follow-up would only \
    make them repeat themselves.
    - They sound rushed, irritated, or reluctant -- unwilling rather than \
    unclear. Someone who did not catch the question is not reluctant.
    - They explicitly decline, or answer in a way that closes the conversation.
    - The audio is silence, noise, or someone else talking.
    - You have nothing genuinely new to learn.

    Stopping early is a good outcome. A short honest interview is worth more \
    than a long extracted one. You may ask at most \(turnsRemaining) more \
    question(s); asking fewer is fine.

    The transcript is their words only -- no timestamps, no speaker labels, no \
    bracketed annotations.

    Reply with ONLY this JSON object and nothing else:
    {"transcript": <string>, "next_question": <string|null>, "is_reask": <true|false>, "rationale": <string>}
    """
  }
}

/// `generateContent` with inline audio.
///
/// Not the Live API, for the same reason Stage 1 is not: this is one bounded
/// request per turn, so a socket held open between turns would buy nothing. It
/// is also what keeps the whole interview loop restartable -- a failed turn is
/// a retry, not a dropped session.
struct GeminiInterviewBrain: InterviewBrain {
  var model: String { CorvusConfig.interviewModel }
  var name: String { "gemini:\(model)" }
  var isConfigured: Bool { !CorvusConfig.geminiAPIKey.isEmpty }

  func decide(
    study: Study,
    item: WatchItem,
    currentQuestion: String,
    history: [BrainTurn],
    answerAudio: Data,
    answerMimeType: String,
    triggerFrame: Data?,
    turnsRemaining: Int
  ) async throws -> BrainDecision {
    let key = CorvusConfig.geminiAPIKey
    guard !key.isEmpty else { throw DetectorError.notConfigured(name) }

    var request = URLRequest(
      url: URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.timeoutInterval = 30

    // The conversation so far, as alternating turns. Prior answers go back as
    // text rather than audio: re-uploading every answer each turn would grow
    // the request without improving the next question.
    var contents: [[String: Any]] = []
    var openingParts: [[String: Any]] = []
    if let triggerFrame, CorvusConfig.sendTriggerFrameToBrain {
      // What they are actually holding, so the model can be concrete about the
      // specific bottle rather than the category.
      openingParts.append([
        "inline_data": ["mime_type": "image/jpeg", "data": triggerFrame.base64EncodedString()]
      ])
    }
    openingParts.append(["text": "This is what they just picked up."])
    contents.append(["role": "user", "parts": openingParts])

    // Completed exchanges, oldest first. Earlier answers go back as text:
    // re-uploading every answer's audio each turn would grow the request
    // without improving the next question.
    for turn in history {
      contents.append(["role": "model", "parts": [["text": turn.question]]])
      contents.append([
        "role": "user",
        "parts": [["text": "They said: \(turn.answerTranscript ?? "(unclear)")"]],
      ])
    }

    contents.append(["role": "model", "parts": [["text": currentQuestion]]])
    contents.append([
      "role": "user",
      "parts": [
        ["inline_data": ["mime_type": answerMimeType, "data": answerAudio.base64EncodedString()]],
        ["text": "That is their latest answer. Transcribe it and decide what to do."],
      ],
    ])

    let body: [String: Any] = [
      "system_instruction": [
        "parts": [["text": InterviewPrompt.system(
          study: study, item: item, turnsRemaining: turnsRemaining)]]
      ],
      "contents": contents,
      "generationConfig": [
        // Not zero: a question phrased identically to every participant starts
        // to sound like a form. Low enough to stay on instruction.
        "temperature": 0.6,
        "responseMimeType": "application/json",
        "maxOutputTokens": 400,
        "thinkingConfig": ["thinkingBudget": 0],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let started = Date()
    let (data, response) = try await send(request)
    let latency = Date().timeIntervalSince(started)

    let bodyText = String(data: data, encoding: .utf8) ?? ""
    guard let http = response as? HTTPURLResponse else {
      throw DetectorError.transport("no HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw DetectorError.badStatus(http.statusCode, bodyText)
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let candidates = root["candidates"] as? [[String: Any]],
          let content = candidates.first?["content"] as? [String: Any],
          let parts = content["parts"] as? [[String: Any]],
          let text = parts.compactMap({ $0["text"] as? String }).first
    else {
      throw DetectorError.unparseable(bodyText)
    }

    return try Self.parse(text, latency: latency)
  }

  /// Reuses the detector's brace matcher: models wrap JSON in prose often
  /// enough that this has already earned its place once.
  static func parse(_ text: String, latency: TimeInterval) throws -> BrainDecision {
    guard let json = DetectionParser.firstJSONObject(in: text),
          let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else { throw DetectorError.unparseable(text) }

    let transcript = (object["transcript"] as? String) ?? ""
    var next = object["next_question"] as? String
    if let candidate = next {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      // A model that means "stop" sometimes says so in prose rather than null.
      let refusals = ["null", "none", "nil", "n/a", ""]
      next = refusals.contains(trimmed.lowercased()) ? nil : trimmed
    }

    return BrainDecision(
      transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
      nextQuestion: next,
      isReask: (object["is_reask"] as? Bool) ?? false,
      rationale: object["rationale"] as? String,
      latency: latency,
      rawResponse: text)
  }
}
