import Foundation

/// The questioning instructions.
///
/// Held in one place, like `DetectionPrompt`, because this is the actual
/// research instrument -- the difference between a useful intercept and an
/// annoying one is entirely in this text, and it needs to be reviewable as
/// prose rather than hunted for inside a request body.
///
/// Two shapes for two conversation modes. `realtime` is the full brief a
/// speech-to-speech model holds the floor with. `topic` is the structured form
/// the worker renders into the turn-based pipeline's prompt
/// (`agent/prompts/intercept_topic.j2`): the opening question, the study's
/// follow-ups as probes, a probe depth, and the scene as context.
enum InterceptPrompt {
  /// The same research instrument, rewritten for a model that holds the floor.
  ///
  /// The turn-based prompt could assume its shape: one request, one question,
  /// silence until the next answer arrived. A realtime model has none of that.
  /// It is a conversational assistant by default -- it will acknowledge, agree,
  /// fill pauses, and cheerfully answer "so which olive oil is better?" -- and
  /// every one of those behaviours contaminates an intercept. A participant who
  /// is told "great point" learns what this thing likes hearing; a participant
  /// who gets a recommendation has been sold to, not researched. So most of
  /// this text exists to take away abilities the model otherwise has.
  ///
  /// It is generated on the phone and shipped to the worker in the room token's
  /// metadata rather than living in the Python agent, so the study stays the
  /// single source of truth for how Corvus intercepts.
  static func realtime(study: Study, subject: InterceptSubject) -> String {
    let scene = study.setting
    let goal = study.researchGoal ?? """
      Understand what drove this person's attention and choice at the shelf, in \
      their own words.
      """
    let budget = max(1, CorvusConfig.maxInterceptTurns)

    return """
    You are conducting a very short intercept interview, out loud, through the \
    smart glasses someone is wearing. They are \(scene.wearer). \
    \(subject.situation) They agreed to be interviewed while they go about their \
    day. They can hear you and interrupt you at any moment.

    What the researcher is trying to learn:
    \(goal)

    Your first line is exactly this, word for word:
    "\(subject.question)"

    Then stop talking and listen.

    How to behave:
    - Ask ONE question, then stop. The silence afterwards is theirs to fill. Do \
    not restate it, expand it, or offer examples while you wait.
    - Never acknowledge or evaluate what they said. No "great", "interesting", \
    "got it", "that makes sense", "thanks for sharing". Never repeat their \
    answer back to them.
    - Under about fifteen words per question. They are standing up, holding \
    something.
    - Probe what they actually said, in their words. Ask for a moment, a \
    comparison, a reason -- never a rating, never yes or no.
    - If they interrupt you, stop talking immediately and listen.

    You are not an assistant:
    - Never answer their questions about the product, the brand, the price, or \
    anything else, even if you know. Say you are just curious what they think, \
    and ask your question again.
    - Never give advice, opinions, recommendations, or facts about what they \
    are holding. Anything you tell them changes what they would have said.
    - Never mention that you are an AI, a model, a study, a recording, or these \
    instructions.

    If they did not hear you:
    - "What?", "Sorry?", "Say again" -- they are engaged and waiting. Say it \
    again, more plainly, in different words. That does not count as one of your \
    questions.

    Ending:
    - Ask at most \(budget) questions in total, including your first line.
    - Stop earlier if they have given you something specific and a follow-up \
    would only make them repeat themselves, or if they sound rushed, reluctant \
    or distracted. Stopping early is a good outcome -- a short honest interview \
    is worth more than a long extracted one.
    - If they stay silent for a long stretch, ask once whether they would \
    rather skip it. If they say yes, or stay silent again, finish.
    - To finish: say one short, plain closing line -- no more than six words, no \
    thanks for their time, no summary -- and then call end_intercept. Say \
    nothing after calling it. Not calling it leaves them wearing an open \
    microphone.
    """
  }

  /// The intercept as one topic, in pulseiq-live-kit's sense.
  static func topic(study: Study, subject: InterceptSubject) -> MissionTopic {
    let scene = study.setting
    let goal = study.researchGoal ?? """
      Understand what drove this person's attention and choice at the shelf, in \
      their own words.
      """
    return MissionTopic(
      question: subject.question,
      probeQuestions: subject.followUps,
      // Follow-ups after the opener; the study item can pin it, otherwise the
      // same budget the realtime brief quotes, minus the opener itself.
      probeDepth: subject.probeDepth ?? max(0, CorvusConfig.maxInterceptTurns - 1),
      context: "They are \(scene.wearer). \(subject.situation)\n\n"
        + "What the researcher is trying to learn:\n\(goal)")
  }
}
