import Combine
import CoreVideo
import Foundation
import UIKit

/// Stage 1, assembled: frames in, interview triggers out.
///
/// Everything upstream of this is a camera and everything downstream is Stage 2,
/// so this is the only place that knows the whole pipeline. It is deliberately
/// source-agnostic -- glasses frames and iPhone frames arrive through the same
/// two entry points, which is what lets the watcher be tuned on a desk.
@MainActor
final class WatcherCoordinator: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var isDetecting = false
  @Published private(set) var lastDetection: Detection?
  @Published private(set) var lastDecision: TriggerDecision?
  @Published private(set) var lastLatency: TimeInterval?
  @Published private(set) var lastError: String?
  @Published private(set) var framesSeen = 0
  @Published private(set) var framesSampled = 0
  @Published private(set) var triggers: [Trigger] = []

  /// Observers of a trigger, for UI. Does not conduct the interview.
  var onTrigger: ((Trigger) -> Void)?

  /// Stage 2. Nil, or interviews disabled, keeps the old behaviour: a trigger
  /// is logged and shown and the lock released immediately, so detection can be
  /// tuned without the glasses talking to anyone.
  var interviewer: Interviewer?

  @Published private(set) var isInterviewing = false
  @Published private(set) var interviews: [InterviewRecord] = []

  /// The configured fieldwork this run belongs to. Items, questions and
  /// thresholds all come from here rather than from code.
  @Published private(set) var study: Study

  private var detector: ProductDetector
  private let sampler = FrameSampler()
  private var machine: TriggerStateMachine
  private let log = CorvusLog.shared

  var watchlist: [WatchItem] { study.items }

  init(study: Study) {
    self.study = study
    self.detector = CorvusConfig.activeDetector.make()
    self.machine = TriggerStateMachine(watchlist: study.items, policy: study.policy)
    self.interviewer = CorvusConfig.interviewer.make()
  }

  func use(_ kind: InterviewerKind) {
    interviewer?.cancel()
    interviewer = kind.make()
    CorvusConfig.interviewer = kind
  }

  /// Switch studies. Rebuilds the machine rather than mutating it: cooldowns
  /// and streaks from the previous study mean nothing under a new watchlist.
  func use(_ study: Study) {
    let wasRunning = isRunning
    if wasRunning { stop() }
    self.study = study
    machine = TriggerStateMachine(watchlist: study.items, policy: study.policy)
    triggers.removeAll()
    lastDetection = nil
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
    isRunning = true
    sampler.reset()
    machine.reset()
    log.append(.init(kind: "watcher_started", at: Date(), detector: detector.name,
                     note: "study=\(study.id)"))
  }

  func stop() {
    isRunning = false
    // Leaving the glasses talking to someone who has taken them off, or into a
    // study that no longer applies, is worse than losing the answer.
    if isInterviewing {
      interviewer?.cancel()
      isInterviewing = false
    }
    log.append(.init(kind: "watcher_stopped", at: Date()))
  }

  /// Stage 2 calls this when an interview finishes, which starts the global
  /// cooldown. Until Stage 2 exists, `handle(trigger:)` calls it immediately.
  func interviewEnded() {
    machine.endInterview(at: Date())
  }

  // MARK: - Frame intake

  func submit(pixelBuffer: CVPixelBuffer) {
    framesSeen += 1
    guard isRunning, !isDetecting, sampler.shouldSample() else { return }
    guard let jpeg = sampler.jpeg(from: pixelBuffer) else { return }
    analyse(jpeg)
  }

  func submit(image: UIImage) {
    framesSeen += 1
    guard isRunning, !isDetecting, sampler.shouldSample() else { return }
    guard let jpeg = sampler.jpeg(from: image) else { return }
    analyse(jpeg)
  }

  // MARK: - Pipeline

  private func analyse(_ jpeg: Data) {
    framesSampled += 1
    // One detector call in flight at a time. Sampling is time-based, so a slow
    // backend would otherwise queue calls that describe a moment already past.
    isDetecting = true
    let detector = self.detector
    let study = self.study

    Task { [weak self] in
      guard let self else { return }
      do {
        // Hop off the main actor for the round trip: base64-encoding a frame
        // and waiting on the network have no business on the UI thread, and
        // this Task inherits main-actor isolation without the detour.
        let outcome = try await self.runDetector(detector, jpeg: jpeg, study: study)
        self.handle(outcome, jpeg: jpeg)
      } catch {
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
    lastDetection = outcome.detection
    lastLatency = outcome.latency
    lastError = nil

    let now = Date()
    let decision = machine.observe(outcome.detection, at: now)
    lastDecision = decision

    var framePath: String?
    if CorvusConfig.captureCorpus || decision.isFired {
      framePath = log.saveFrame(jpeg, tag: outcome.detection.itemID ?? "frame")
    }

    log.append(.init(
      kind: "detection",
      at: now,
      detector: outcome.detectorName,
      latencyMS: Int(outcome.latency * 1000),
      holding: outcome.detection.holding,
      itemID: outcome.detection.itemID,
      productGuess: outcome.detection.productGuess,
      confidence: outcome.detection.confidence,
      decision: decision.label,
      framePath: framePath))

    if case .fired(let trigger) = decision {
      triggers.insert(trigger, at: 0)
      log.append(.init(
        kind: "trigger",
        at: trigger.firedAt,
        itemID: trigger.item.id,
        confidence: trigger.confidence,
        framePath: framePath,
        note: trigger.item.question))
      NSLog("[Corvus] TRIGGER %@ (confidence %.2f, %d hits)",
            trigger.item.id, trigger.confidence, trigger.hitCount)

      onTrigger?(trigger)

      if let interviewer, CorvusConfig.interviewsEnabled {
        // The machine stays locked for the whole interview -- that is what
        // stops a second pickup mid-question -- and is released on the way out
        // whatever happened, including a thrown route failure.
        isInterviewing = true
        let study = self.study
        // The frame that fired the trigger, so the interviewer can be concrete
        // about the actual product rather than the category.
        let frame = CorvusConfig.sendTriggerFrameToBrain ? jpeg : nil
        Task { [weak self] in
          let record = await interviewer.conduct(trigger, study: study, frame: frame)
          guard let self else { return }
          self.interviews.insert(record, at: 0)
          self.isInterviewing = false
          self.machine.endInterview(at: Date())
        }
      } else {
        // No Stage 2. Release the lock straight away so a test run can reach
        // more than one pickup; the per-item cooldown still applies.
        machine.endInterview(at: now)
      }
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
    case .fired(let t): return "fired:\(t.item.id)"
    case .notHolding: return "not_holding"
    case .notOnWatchlist(let guess): return "off_list:\(guess ?? "unknown")"
    case .belowConfidence(let c): return String(format: "low_confidence:%.2f", c)
    case .buildingStreak(let id, let hits, let needed): return "streak:\(id):\(hits)/\(needed)"
    case .itemCoolingDown(let id, _): return "item_cooldown:\(id)"
    case .globallyLocked: return "locked"
    }
  }
}
