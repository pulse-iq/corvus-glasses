import Foundation

/// Stage 1 configuration.
///
/// iOS has no process environment to read, so keys resolve in this order:
///   1. UserDefaults (set from the debug panel, handy for swapping keys on device)
///   2. `Secrets.swift` -- gitignored, copied from `Secrets.swift.example`
/// Model ids are overridable the same way so a new model can be benchmarked
/// without a rebuild.
enum CorvusConfig {
  // MARK: - Keys

  static var geminiAPIKey: String { resolve("corvus.geminiAPIKey", fallback: Secrets.geminiAPIKey) }
  static var openAIAPIKey: String { resolve("corvus.openAIAPIKey", fallback: Secrets.corvusOpenAIAPIKey) }
  static var anthropicAPIKey: String { resolve("corvus.anthropicAPIKey", fallback: Secrets.corvusAnthropicAPIKey) }

  // MARK: - Models
  //
  // Verify these against current provider docs before trusting benchmark
  // numbers; model ids move faster than this file does.

  static var geminiFlashLiteModel: String { resolve("corvus.model.geminiFlashLite", fallback: "gemini-2.5-flash-lite") }
  static var geminiFlashModel: String { resolve("corvus.model.geminiFlash", fallback: "gemini-2.5-flash") }
  static var openAIVisionModel: String { resolve("corvus.model.openAI", fallback: "gpt-5-mini") }
  static var anthropicVisionModel: String { resolve("corvus.model.anthropic", fallback: "claude-haiku-4-5") }

  // MARK: - Sampling

  /// Frames per second handed to the detector. The glasses stream at 24fps;
  /// everything above ~1fps is spend without extra signal, because a shopper
  /// holds a product for seconds, not frames.
  static var samplesPerSecond: Double { resolveDouble("corvus.samplesPerSecond", fallback: 1.0) }

  /// Longest edge of the JPEG sent to the model. 768 keeps a product label
  /// legible while staying inside the cheap image tier for every provider.
  static var frameMaxDimension: CGFloat { CGFloat(resolveDouble("corvus.frameMaxDimension", fallback: 768)) }

  static var frameJPEGQuality: CGFloat { CGFloat(resolveDouble("corvus.frameJPEGQuality", fallback: 0.7)) }

  /// Whether to open upstream's LiveKit voice call alongside the watcher.
  ///
  /// Off: Stage 2's architecture is undecided, and upstream's call routes
  /// through a hosted gateway we have no account on -- so every launch opened a
  /// room that could only fail, put "Gateway not configured" over the camera,
  /// and held the mic and radio for nothing. Flip it on to exercise the LiveKit
  /// path once we have a gateway of our own.
  static var useLiveKitCall: Bool {
    get { UserDefaults.standard.bool(forKey: "corvus.useLiveKitCall") }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.useLiveKitCall") }
  }

  /// Whether the watcher runs on the live camera screen at all.
  ///
  /// Off means no frames go to a vision model from that screen -- the switch is
  /// as much about spend as about clutter, since a watched trip is a detector
  /// call roughly every second and a half.
  static var watchOnCameraScreen: Bool {
    get { UserDefaults.standard.object(forKey: "corvus.watchOnCameraScreen") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.watchOnCameraScreen") }
  }

  /// Whether to draw the Stage 1 readout over the camera.
  ///
  /// On for development, because a silent screen cannot distinguish "working
  /// and correctly quiet" from "broken". Turn it off before a participant wears
  /// the glasses: a debug overlay changes how someone behaves on camera.
  static var showWatcherHUD: Bool {
    get { UserDefaults.standard.object(forKey: "corvus.showWatcherHUD") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.showWatcherHUD") }
  }

  /// Detector to use in the app. Benchmarking across the others happens
  /// offline, against saved frames.
  static var activeDetector: DetectorKind {
    get {
      guard let raw = UserDefaults.standard.string(forKey: "corvus.activeDetector"),
            let kind = DetectorKind(rawValue: raw)
      else { return .geminiFlashLite }
      return kind
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "corvus.activeDetector") }
  }

  /// Write every sampled frame to disk alongside its verdict. Off by default --
  /// it is how the offline benchmark corpus gets built, not something to leave
  /// running during a session.
  static var captureCorpus: Bool {
    get { UserDefaults.standard.bool(forKey: "corvus.captureCorpus") }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.captureCorpus") }
  }

  // MARK: - Stage 2

  /// Whether a trigger actually starts an interview. Off leaves Stage 1
  /// exactly as it was -- trigger, banner, log, no sound -- which is what you
  /// want while tuning detection thresholds.
  static var interviewsEnabled: Bool {
    get { UserDefaults.standard.object(forKey: "corvus.interviewsEnabled") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.interviewsEnabled") }
  }

  static var interviewer: InterviewerKind {
    get {
      guard let raw = UserDefaults.standard.string(forKey: "corvus.interviewer"),
            let kind = InterviewerKind(rawValue: raw)
      else { return .conversational }
      return kind
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "corvus.interviewer") }
  }

  /// Both routes were measured working with DAT streaming; this is a fidelity
  /// versus isolation choice, not a capability one. Glasses-both-ways wins
  /// wherever there is background noise, which is the real setting.
  static var audioRouteMode: AudioRouteMode {
    get {
      guard let raw = UserDefaults.standard.string(forKey: "corvus.audioRouteMode"),
            let mode = AudioRouteMode(rawValue: raw)
      else { return .glassesBothWays }
      return mode
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "corvus.audioRouteMode") }
  }

  /// Substrings that identify the glasses among the audio devices on offer.
  /// Needed because a participant with earbuds connected presents several
  /// Bluetooth inputs, and picking the wrong one interviews them through the
  /// wrong microphone without ever erroring.
  static var glassesAudioNameHints: [String] {
    if let raw = UserDefaults.standard.string(forKey: "corvus.glassesAudioNameHints"),
       !raw.isEmpty {
      return raw.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
    }
    return ["RB Meta", "Ray-Ban", "Ray Ban", "Oakley Meta"]
  }

  // MARK: - Conversational interviewing

  /// Model that listens to each answer and chooses the next question. Flash
  /// rather than Flash-Lite: this is the one call in the system that needs
  /// judgement rather than classification, and it happens a handful of times per
  /// interview instead of once a second.
  static var interviewModel: String {
    resolve("corvus.model.interview", fallback: "gemini-2.5-flash")
  }

  /// Total questions including the study's opener. Three is one opener plus two
  /// probes -- past that an intercept stops being an intercept.
  static var maxInterviewTurns: Int {
    let v = UserDefaults.standard.integer(forKey: "corvus.maxInterviewTurns")
    return v > 0 ? v : 3
  }

  /// How many times the interview may repeat itself when the wearer asks it to.
  /// These do not count against `maxInterviewTurns` -- being asked "what?" is
  /// not a turn of the interview -- but they are capped, because repeating a
  /// third time is its own kind of pushing.
  static var maxReasks: Int {
    let v = UserDefaults.standard.integer(forKey: "corvus.maxReasks")
    return v > 0 ? v : 2
  }

  /// Send the frame that fired the trigger along with the first answer, so the
  /// model can name the actual product rather than the category. Costs one
  /// image per interview.
  static var sendTriggerFrameToBrain: Bool {
    get { UserDefaults.standard.object(forKey: "corvus.sendTriggerFrameToBrain") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.sendTriggerFrameToBrain") }
  }

  // MARK: - Answer capture

  /// How long to wait for someone to start talking at all. Generous, because
  /// this is thinking time and ending it early records nothing but the pause;
  /// it only stops a wearer who ignored the question entirely.
  static var maxWaitForSpeechSeconds: Double {
    resolveDouble("corvus.maxWaitForSpeechSeconds", fallback: 12)
  }

  /// Level that counts as someone starting to speak. Set from field traces:
  /// speech lands at -17 to -25 dB, room ambience at -45 to -55, true silence
  /// below -85, so this sits in the gap with room on both sides.
  static var speechOnsetDB: Double {
    let v = UserDefaults.standard.double(forKey: "corvus.speechOnsetDB")
    return v < 0 ? v : -40
  }
  /// Hard ceiling, so a forgotten session cannot record the rest of the trip.
  static var maxAnswerSeconds: Double { resolveDouble("corvus.maxAnswerSeconds", fallback: 45) }
  /// Continuous quiet that counts as "finished speaking".
  ///
  /// This is dead air the wearer sits through on every single turn, so it is
  /// worth being precise rather than safe. Measured field traces put the
  /// longest pause *inside* an answer at 0.4s; 1.2s is three times that and
  /// still a second faster than the two seconds it replaces. It is the only
  /// part of the turnaround that is ours to shorten -- the rest is the model
  /// thinking, and no amount of tuning removes it.
  static var silenceSeconds: Double { resolveDouble("corvus.silenceSeconds", fallback: 1.2) }
  /// Absolute floor, used only before anything has been heard. Lowered from the
  /// original -35 on field evidence: a real answer ("um, the price") peaked at
  /// -35.7 dB, so the whole utterance read as silence and survived only because
  /// the minimum duration covered it.
  static var silenceThresholdDB: Double {
    let v = UserDefaults.standard.double(forKey: "corvus.silenceThresholdDB")
    return v < 0 ? v : -50
  }

  /// How far below the loudest speech heard so far still counts as speech.
  /// Relative, because the gap between a mumble and a shout is much larger than
  /// the gap between speech and the pauses inside it.
  static var silenceDropDB: Double { resolveDouble("corvus.silenceDropDB", fallback: 18) }

  // MARK: - Transcription

  static var transcribeAnswers: Bool {
    get { UserDefaults.standard.object(forKey: "corvus.transcribeAnswers") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "corvus.transcribeAnswers") }
  }

  static var transcriptionModel: String {
    resolve("corvus.model.transcription", fallback: "gpt-4o-mini-transcribe")
  }

  /// Vocabulary hint sent with each transcription. Product names are precisely
  /// what a general model mishears, and they are the words that matter most.
  static var transcriptionPrompt: String {
    resolve(
      "corvus.transcriptionPrompt",
      fallback: "A shopper describing groceries: olive oil, yogurt, milk, lettuce, "
        + "carrots, eggs, spaghetti, sour cream.")
  }

  // MARK: - Resolution

  private static func resolve(_ key: String, fallback: String) -> String {
    if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
    return fallback.hasPrefix("YOUR_") ? "" : fallback
  }

  private static func resolveDouble(_ key: String, fallback: Double) -> Double {
    let v = UserDefaults.standard.double(forKey: key)
    return v > 0 ? v : fallback
  }
}
