import Foundation

/// Tuning for how eagerly Stage 1 interrupts a shopper.
///
/// Every value here trades a missed interview against a bad one. Defaults lean
/// conservative: a missed pickup costs one data point, while a spurious
/// interview costs the participant's trust and contaminates the session.
struct TriggerPolicy: Equatable {
  /// Below this, a hit does not count towards the streak at all.
  var minConfidence: Double = 0.6
  /// How many hits on the same item are needed before firing. One frame is not
  /// evidence -- the model will occasionally see a jar in a hand that is
  /// reaching past it.
  var consecutiveHits: Int = 2
  /// Hits must fall inside this window to count as a streak. Sampling at ~1fps,
  /// this tolerates a blurred or dropped frame between two good ones without
  /// letting a hit from twenty seconds ago prop up a new streak.
  ///
  /// Must exceed `consecutiveHits` x detector round-trip, or the streak can
  /// never complete. Measured p50s: Gemini Flash-Lite ~1.5s, Gemini Flash
  /// ~1.6s, Claude Haiku ~2.4s, gpt-5-mini ~4.8s. Six seconds fits the Gemini
  /// and Haiku backends comfortably; gpt-5-mini needs roughly double before it
  /// can ever fire, so widen this when benchmarking it.
  var streakWindow: TimeInterval = 6
  /// How long before the same product may trigger again. Long, because the item
  /// stays in the cart and keeps appearing in frame.
  var perItemCooldown: TimeInterval = 600
  /// Quiet period after an interview ends, so two pickups in a row do not
  /// become two back-to-back interviews.
  var globalCooldown: TimeInterval = 90
  /// Safety valve: if Stage 2 never reports back (crash, dropped session), the
  /// watcher un-sticks itself instead of going silent for the rest of the trip.
  var maxInterviewDuration: TimeInterval = 120

  static let `default` = TriggerPolicy()
}

/// A decision to interview, with the evidence that produced it.
struct Trigger: Equatable {
  let item: WatchItem
  let firedAt: Date
  /// Highest confidence among the hits that formed the streak.
  let confidence: Double
  let hitCount: Int
}

/// Why a frame did not trigger. Surfaced in the debug panel and the logs --
/// during tuning, knowing *which* gate rejected a pickup is the whole game.
enum TriggerDecision: Equatable {
  case fired(Trigger)
  case notHolding
  case notOnWatchlist(String?)
  case belowConfidence(Double)
  case buildingStreak(itemID: String, hits: Int, needed: Int)
  case itemCoolingDown(itemID: String, until: Date)
  case globallyLocked(until: Date?)
}

/// Turns a stream of per-frame verdicts into interview triggers.
///
/// Pure and clock-injected: every decision is a function of the detections it
/// has been shown and the timestamps it was given, so the whole policy is
/// testable without a camera, a network, or a wall clock.
final class TriggerStateMachine {
  private struct Hit {
    let itemID: String
    let at: Date
    let confidence: Double
  }

  private let watchlist: [WatchItem]
  private(set) var policy: TriggerPolicy

  private var streak: [Hit] = []
  private var lastTriggeredByItem: [String: Date] = [:]
  /// Set while an interview is in flight or its cooldown is running. nil means
  /// the watcher is free to fire.
  private var lockedUntil: Date?
  private var interviewStartedAt: Date?

  init(watchlist: [WatchItem], policy: TriggerPolicy = .default) {
    self.watchlist = watchlist
    self.policy = policy
  }

  /// Feed one detection. Returns what the machine decided and why.
  func observe(_ detection: Detection, at now: Date) -> TriggerDecision {
    // An interview that overran its safety ceiling releases the lock outright;
    // otherwise a dropped Stage 2 session would silence the rest of the trip.
    // Deliberately not endInterview(): that would stack a fresh global cooldown
    // on top of the timeout just served, and the watcher has already been quiet
    // for maxInterviewDuration. The per-item cooldown still guards the product
    // whose interview was lost.
    if let started = interviewStartedAt, now.timeIntervalSince(started) > policy.maxInterviewDuration {
      interviewStartedAt = nil
      lockedUntil = nil
    }

    if let until = lockedUntil {
      if interviewStartedAt != nil || now < until {
        return .globallyLocked(until: interviewStartedAt == nil ? until : nil)
      }
      lockedUntil = nil
    }

    guard detection.holding else {
      // Putting the product down ends the candidacy immediately -- that is a
      // real signal, not a dropped frame.
      streak.removeAll()
      return .notHolding
    }
    guard let itemID = detection.itemID else {
      streak.removeAll()
      return .notOnWatchlist(detection.productGuess)
    }
    guard detection.confidence >= policy.minConfidence else {
      return .belowConfidence(detection.confidence)
    }
    guard let item = Watchlist.item(withID: itemID, in: watchlist) else {
      return .notOnWatchlist(detection.productGuess)
    }

    if let last = lastTriggeredByItem[itemID] {
      let ready = last.addingTimeInterval(policy.perItemCooldown)
      if now < ready {
        return .itemCoolingDown(itemID: itemID, until: ready)
      }
    }

    // A different product starts a fresh streak; misses simply age out, so one
    // blurred frame between two clean ones does not cost the trigger.
    if streak.first?.itemID != itemID {
      streak.removeAll()
    }
    streak.append(Hit(itemID: itemID, at: now, confidence: detection.confidence))
    streak.removeAll { now.timeIntervalSince($0.at) > policy.streakWindow }

    guard streak.count >= policy.consecutiveHits else {
      return .buildingStreak(itemID: itemID, hits: streak.count, needed: policy.consecutiveHits)
    }

    let trigger = Trigger(
      item: item,
      firedAt: now,
      confidence: streak.map(\.confidence).max() ?? detection.confidence,
      hitCount: streak.count)

    lastTriggeredByItem[itemID] = now
    streak.removeAll()
    // Hold the lock open-ended: the global cooldown should run from when the
    // interview *ends*, not when it starts, or a 45s interview eats most of it.
    interviewStartedAt = now
    lockedUntil = now.addingTimeInterval(policy.maxInterviewDuration)
    return .fired(trigger)
  }

  /// Stage 2 reports back here. Starts the global cooldown.
  func endInterview(at now: Date) {
    interviewStartedAt = nil
    lockedUntil = now.addingTimeInterval(policy.globalCooldown)
  }

  func update(policy newPolicy: TriggerPolicy) {
    policy = newPolicy
  }

  /// Full reset between participants or test runs.
  func reset() {
    streak.removeAll()
    lastTriggeredByItem.removeAll()
    lockedUntil = nil
    interviewStartedAt = nil
  }
}
