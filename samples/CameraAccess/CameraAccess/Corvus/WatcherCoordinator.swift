import Combine
import CoreVideo
import ImageIO
import Foundation
import UIKit

/// The watcher, assembled: frames in, intercept triggers out.
///
/// Everything upstream of this is a camera and everything downstream is an
/// intercept, so this is the only place that knows the whole pipeline. It is
/// deliberately source-agnostic -- glasses frames and iPhone frames arrive
/// through the same two entry points, which is what lets the watcher be tuned
/// on a desk.
@MainActor
final class WatcherCoordinator: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var isDetecting = false
  @Published private(set) var lastObservation: Observation?
  @Published private(set) var lastDecision: TriggerDecision?
  @Published private(set) var lastLatency: TimeInterval?
  @Published private(set) var lastError: String?
  @Published private(set) var framesSeen = 0
  @Published private(set) var framesSampled = 0
  @Published private(set) var triggers: [Trigger] = []

  /// Observers of a trigger, for UI. Does not conduct the intercept.
  var onTrigger: ((Trigger) -> Void)?

  /// The interceptor. Nil, or disabled, keeps the old behaviour: a trigger
  /// is logged and shown and the lock released immediately, so detection can be
  /// tuned without the glasses talking to anyone.
  var interceptor: Interceptor?

  @Published private(set) var isIntercepting = false
  @Published private(set) var intercepts: [InterceptRecord] = []

  /// The configured fieldwork this run belongs to. Items, questions and
  /// thresholds all come from here rather than from code.
  @Published private(set) var study: Study

  private var detectionGeneration = 0
  private var runGeneration = 0
  private var missionReady = true
  func setMissionReady(_ ready: Bool) {
    guard missionReady != ready else { return }
    missionReady = ready
    detectionGeneration += 1
    isDetecting = false
    machine.clearEvidence()
  }

  private var detector: ProductDetector
  private let sampler = FrameSampler()
  private var machine: TriggerStateMachine
  private let log = CorvusLog.shared

  var watchlist: [WatchItem] { study.items }
  var sections: [WatchCategory] { study.categories }

  init(study: Study) {
    self.study = study
    self.detector = CorvusConfig.activeDetector.make()
    self.machine = TriggerStateMachine(study: study)
    self.interceptor = CorvusConfig.interceptor.make()
  }

  /// The realtime interceptor talks through the call screen's own room, so it
  /// needs the session that screen owns. Passed in rather than reached for
  /// globally, because a second LiveKit room would fight this one for the mic.
  private weak var liveKit: LiveKitSession?

  func attach(liveKit: LiveKitSession) {
    self.liveKit = liveKit
    if CorvusConfig.interceptor == .liveKit {
      interceptor = InterceptorKind.liveKit.make(liveKit: liveKit)
    }
  }

  func use(_ kind: InterceptorKind) {
    interceptor?.cancel()
    interceptor = kind.make(liveKit: liveKit)
    CorvusConfig.interceptor = kind
  }

  /// Switch studies. Rebuilds the machine rather than mutating it: cooldowns
  /// and streaks from the previous study mean nothing under a new watchlist.
  func use(_ study: Study) {
    let wasRunning = isRunning
    if wasRunning { stop() }
    self.study = study
    machine = TriggerStateMachine(study: study)
    triggers.removeAll()
    lastObservation = nil
    lastDecision = nil
    if wasRunning { start() }
  }

  var detectorName: String { detector.name }
  var isConfigured: Bool { detector.isConfigured }

  func use(_ kind: DetectorKind) {
    detector = kind.make()
    CorvusConfig.activeDetector = kind
    lastError = nil
  }

  func start() {
    guard !isRunning else { return }
    runGeneration += 1
    isRunning = true
    sampler.reset()
    machine.reset()
    log.append(.init(kind: "watcher_started", at: Date(), detector: detector.name,
                     note: "study=\(study.id)"))
  }

  func stop() {
    runGeneration += 1
    detectionGeneration += 1
    isDetecting = false
    isRunning = false
    // Leaving the glasses talking to someone who has taken them off, or into a
    // study that no longer applies, is worse than losing the answer.
    if isIntercepting {
      interceptor?.cancel()
      isIntercepting = false
    }
    log.append(.init(kind: "watcher_stopped", at: Date()))
  }

  /// The interceptor calls this when an intercept finishes, which starts the
  /// global cooldown. With no interceptor, `handle(trigger:)` calls it at once.
  func interceptEnded() {
    machine.endIntercept(at: Date())
  }

  // MARK: - Frame intake

  func submit(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) {
    framesSeen += 1
    guard isRunning, missionReady, !isDetecting, sampler.shouldSample() else { return }
    guard let jpeg = sampler.jpeg(from: pixelBuffer, orientation: orientation) else { return }
    analyse(jpeg)
  }

  func submit(image: UIImage) {
    framesSeen += 1
    guard isRunning, missionReady, !isDetecting, sampler.shouldSample() else { return }
    guard let jpeg = sampler.jpeg(from: image) else { return }
    analyse(jpeg)
  }

  // MARK: - Pipeline

  private func analyse(_ jpeg: Data) {
    framesSampled += 1
    // One detector call in flight at a time. Sampling is time-based, so a slow
    // backend would otherwise queue calls that describe a moment already past.
    isDetecting = true
    let generation = detectionGeneration
    let detector = self.detector
    let study = self.study

    Task { [weak self] in
      guard let self else { return }
      do {
        // Hop off the main actor for the round trip: base64-encoding a frame
        // and waiting on the network have no business on the UI thread, and
        // this Task inherits main-actor isolation without the detour.
        let outcome = try await self.runDetector(detector, jpeg: jpeg, study: study)
        guard self.isRunning, self.missionReady, generation == self.detectionGeneration else { return }
        self.handle(outcome, jpeg: jpeg)
      } catch {
        guard generation == self.detectionGeneration else { return }
        self.handle(error, detectorName: detector.name)
      }
    }
  }

  private nonisolated func runDetector(
    _ detector: ProductDetector, jpeg: Data, study: Study
  ) async throws -> DetectionOutcome {
    try await detector.detect(jpeg: jpeg, study: study)
  }

  private func handle(_ outcome: DetectionOutcome, jpeg: Data) {
    isDetecting = false
    let observation = outcome.observation
    lastObservation = observation
    lastLatency = outcome.latency
    lastError = nil

    let now = Date()
    let result = machine.observe(observation, at: now)
    lastDecision = result.decision

    var framePath: String?
    if CorvusConfig.captureCorpus || result.decision.isFired {
      framePath = log.saveFrame(jpeg, tag: observation.held.first?.itemID ?? "frame")
    }

    // Every frame, matched or not. A frame where nothing was held is not a
    // non-event: it is the other half of every transition, and the only reason
    // a trip can be replayed offline instead of walked again.
    let best = observation.held.max { $0.confidence < $1.confidence }
    log.append(.init(
      kind: "detection",
      at: now,
      detector: outcome.detectorName,
      latencyMS: Int(outcome.latency * 1000),
      holding: observation.isHolding,
      itemID: best?.itemID,
      categoryID: best?.categoryID,
      productGuess: best?.productGuess,
      examining: best?.examining,
      facingCategoryID: observation.facing?.categoryID,
      scene: observation.scene.rawValue,
      heldCount: observation.held.count,
      confidence: best?.confidence,
      decision: result.decision.label,
      framePath: framePath,
      observation: observation))

    // Primitives that fired and lost. Recorded before the winner so the trace
    // reads in the order the frame was judged, and kept at all because the
    // moment a dwell lost to is what would have made its question a good one.
    for loser in result.alsoFired {
      log.append(.init(
        kind: "trigger_suppressed",
        at: loser.firedAt,
        itemID: loser.subject.targetID,
        confidence: loser.confidence,
        primitive: loser.primitive.rawValue,
        targetID: loser.target.id,
        note: loser.subject.situation))
    }

    guard case .fired(let trigger) = result.decision else { return }

    triggers.insert(trigger, at: 0)
    log.append(.init(
      kind: "trigger",
      at: trigger.firedAt,
      itemID: trigger.subject.targetID,
      confidence: trigger.confidence,
      primitive: trigger.primitive.rawValue,
      targetID: trigger.target.id,
      framePath: framePath,
      note: trigger.subject.question))
    NSLog("[Corvus] TRIGGER %@ on %@ (confidence %.2f, %d hits)",
          trigger.primitive.rawValue, trigger.subject.targetID,
          trigger.confidence, trigger.hitCount)

    onTrigger?(trigger)

    guard let interceptor, CorvusConfig.interceptsEnabled else {
      // No interceptor. Release the lock straight away so a test run can reach
      // more than one trigger; the per-target cooldown still applies.
      machine.endIntercept(at: now)
      return
    }

    // The machine stays locked for the whole intercept -- that is what stops a
    // second pickup mid-question -- and is released on the way out whatever
    // happened, including a thrown route failure.
    isIntercepting = true
    let study = self.study
    // The frame that fired the trigger, so the interceptor can be concrete
    // about the actual product rather than the category.
    let frame = CorvusConfig.sendTriggerFrameToBrain ? jpeg : nil
    let generation = runGeneration
    Task { [weak self] in
      let record = await interceptor.conduct(trigger, study: study, frame: frame)
      guard let self else { return }
      self.intercepts.insert(record, at: 0)
      guard generation == self.runGeneration else { return }
      self.isIntercepting = false
      self.machine.endIntercept(at: Date())
    }
  }

  private func handle(_ error: Error, detectorName: String) {
    isDetecting = false
    let message = (error as? DetectorError)?.localizedDescription ?? error.localizedDescription
    lastError = message
    log.append(.init(kind: "detector_error", at: Date(), detector: detectorName, error: message))
    NSLog("[Corvus] detector error: %@", message)
  }
}

extension TriggerDecision {
  var isFired: Bool {
    if case .fired = self { return true }
    return false
  }

  /// Short, stable string for logs and the debug panel.
  var label: String {
    switch self {
    case .fired(let t): return "fired:\(t.primitive.rawValue):\(t.subject.targetID)"
    case .building(let progress):
      return progress.map(\.label).joined(separator: " ")
    case .quiet(let guess): return guess.map { "quiet:off_list:\($0)" } ?? "quiet"
    case .targetCoolingDown(let id, _): return "cooldown:\(id)"
    case .globallyLocked: return "locked"
    case .budgetSpent(let used, let limit): return "budget_spent:\(used)/\(limit)"
    }
  }
}
