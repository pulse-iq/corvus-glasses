import Foundation

/// The kinds of moment the watcher can recognise.
///
/// Each is a predicate over the observation stream, not a detector: they all
/// read the same frame call, and adding one must never add a second. Order
/// here is arbitrary; `priority` is what arbitration uses.
enum PrimitiveKind: String, CaseIterable, Codable, Equatable {
  /// Two or more of a section's products in the hands at once.
  case comparing
  /// Held up close and read, rather than carried.
  case examining
  /// In the hands at all. The original watcher, and still the backbone.
  case holding
  /// Stopped in front of a section, hands empty or otherwise.
  case dwell

  /// Higher wins when several fire on the same frame.
  ///
  /// The order is by how much the moment narrows down what to ask. Someone
  /// weighing two jars against each other has told you more than someone
  /// merely holding one, and anyone holding anything has told you more than
  /// someone standing in an aisle.
  var priority: Int {
    switch self {
    case .comparing: return 30
    case .examining: return 20
    case .holding: return 10
    case .dwell: return 0
    }
  }

  /// Which targets this kind can be aimed at.
  ///
  /// `comparing` and `dwell` are about a range rather than a product: two of
  /// the same item is not a comparison, and you cannot stand in front of a
  /// single jar.
  var acceptsItems: Bool {
    switch self {
    case .holding, .examining: return true
    case .comparing, .dwell: return false
    }
  }

  /// What a study gets when it does not say. Everything the target can support
  /// -- narrowing is the study author's decision, not a default.
  static func applicable(toItem: Bool) -> [PrimitiveKind] {
    allCases.filter { !toItem || $0.acceptsItems }
  }
}

/// Per-primitive tuning. Every value trades a missed intercept against a bad
/// one, and the exchange rate differs by primitive -- which is why these are
/// not one global set of thresholds.
struct PrimitivePolicy: Equatable {
  var enabled: Bool
  /// Below this, a frame does not count towards the streak at all.
  var minConfidence: Double
  /// How many frames are needed before firing. One frame is not evidence --
  /// the model will occasionally see a jar in a hand that is reaching past it.
  var consecutiveHits: Int
  /// Hits must fall inside this window to count as a streak. Sampling at
  /// ~1fps, this tolerates a blurred or dropped frame between two good ones
  /// without letting a hit from twenty seconds ago prop up a new streak.
  ///
  /// Must exceed `consecutiveHits` x detector round-trip, or the streak can
  /// never complete. Measured p50s: Gemini Flash-Lite ~1.5s, Gemini Flash
  /// ~1.6s, Claude Haiku ~2.4s, gpt-5-mini ~4.8s. gpt-5-mini needs roughly
  /// double these windows before it can ever fire.
  var streakWindow: TimeInterval
  /// How long before the same target may fire this primitive again.
  var cooldown: TimeInterval

  static func `default`(for kind: PrimitiveKind) -> PrimitivePolicy {
    switch kind {
    case .holding:
      // The tuned baseline everything else is calibrated against. The long
      // cooldown is because the product stays in the cart and keeps appearing.
      return .init(
        enabled: true, minConfidence: 0.6, consecutiveHits: 2, streakWindow: 6, cooldown: 600)
    case .examining:
      // Same evidence bar as holding, since it is holding plus one flag, but a
      // shorter cooldown: going back to re-read a label is itself a moment.
      return .init(
        enabled: true, minConfidence: 0.6, consecutiveHits: 2, streakWindow: 6, cooldown: 300)
    case .comparing:
      // A lower floor on purpose. Two watched products in two hands is a strong
      // structural signal even when neither label reads cleanly, and this is
      // the most informative moment in a shop -- worth catching at lower
      // per-product confidence than a plain pickup.
      return .init(
        enabled: true, minConfidence: 0.5, consecutiveHits: 2, streakWindow: 6, cooldown: 300)
    case .dwell:
      // Much more evidence, because standing still is far weaker evidence than
      // picking something up, and far more frequent: a trip has tens of pickups
      // and hundreds of dwell-seconds. Five hits across twelve seconds is about
      // seven seconds of genuinely standing there. The long cooldown stops one
      // aisle being asked about twice.
      return .init(
        enabled: true, minConfidence: 0.5, consecutiveHits: 5, streakWindow: 12, cooldown: 900)
    }
  }
}

/// What one primitive made of one frame.
enum PrimitiveOutcome: Equatable {
  /// Nothing relevant in this frame.
  case idle
  /// The target was there but scored under the floor. Kept distinct from
  /// `idle` because during tuning "confidence 0.41 on olive oil" and "saw no
  /// hands" call for opposite fixes, and one bucket cannot tell them apart.
  case belowConfidence(Double)
  case building(hits: Int, needed: Int)
  case fired(confidence: Double, hitCount: Int, evidence: TriggerEvidence)
}

/// What the model actually saw when a primitive fired.
///
/// Carried into the intercept so it can name the wearer's real brand rather
/// than the study's slug, and into the log so a trigger can be judged after the
/// fact without the frame.
struct TriggerEvidence: Equatable, Codable {
  /// The model's own words for the products involved.
  var products: [String] = []
  var scene: SceneKind = .other
}

/// A predicate over the observation stream.
///
/// Pure and clock-injected in the same sense the machine is: every decision is
/// a function of the observations it has been shown and the timestamps it was
/// given. No primitive reads a clock, a camera or a network, which is what
/// keeps the whole policy testable without any of them.
protocol TriggerPrimitive: AnyObject {
  var kind: PrimitiveKind { get }
  var target: WatchTarget { get }
  func observe(_ o: Observation, at now: Date, policy: PrimitivePolicy) -> PrimitiveOutcome
  func reset()
}

/// Hits inside a rolling window.
///
/// Misses age out rather than clearing, so one blurred frame between two clean
/// ones does not cost a trigger. Only a frame that positively contradicts the
/// primitive clears it, and deciding what counts as a contradiction is each
/// primitive's own business.
struct StreakTracker: Equatable {
  private struct Hit: Equatable {
    let at: Date
    let confidence: Double
  }

  private var hits: [Hit] = []

  var count: Int { hits.count }
  var best: Double { hits.map(\.confidence).max() ?? 0 }

  mutating func add(_ confidence: Double, at now: Date, window: TimeInterval) {
    hits.append(Hit(at: now, confidence: confidence))
    hits.removeAll { now.timeIntervalSince($0.at) > window }
  }

  mutating func clear() { hits.removeAll() }
}

// MARK: - Held-product primitives

/// Shared body of the primitives that are about something in the hands.
///
/// `holding` and `examining` differ by one predicate, so they are one class
/// with a filter rather than two near-identical ones -- a divergence between
/// them would be a bug, not a feature.
final class HeldPrimitive: TriggerPrimitive {
  let kind: PrimitiveKind
  let target: WatchTarget
  private let requiresExamining: Bool
  private var streak = StreakTracker()

  init(kind: PrimitiveKind, target: WatchTarget) {
    self.kind = kind
    self.target = target
    self.requiresExamining = kind == .examining
  }

  func reset() { streak.clear() }

  func observe(_ o: Observation, at now: Date, policy: PrimitivePolicy) -> PrimitiveOutcome {
    let candidates = o.held(matching: target)
      .filter { !requiresExamining || $0.examining }
    guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
      // Putting the product down, or lowering it out of reading position, ends
      // the candidacy immediately. That is a real signal, not a dropped frame.
      streak.clear()
      return .idle
    }
    guard best.confidence >= policy.minConfidence else {
      // Deliberately does not clear: a single low-confidence read between two
      // good ones is exactly the blur the streak window exists to absorb.
      return .belowConfidence(best.confidence)
    }

    streak.add(best.confidence, at: now, window: policy.streakWindow)
    guard streak.count >= policy.consecutiveHits else {
      return .building(hits: streak.count, needed: policy.consecutiveHits)
    }
    return .fired(
      confidence: streak.best,
      hitCount: streak.count,
      evidence: TriggerEvidence(products: [best.productGuess].compactMap { $0 }, scene: o.scene))
  }
}

/// Two or more of a section's products in the hands at once.
///
/// The tradeoff moment, and the one frame in a shopping trip where the wearer
/// has already done the researcher's work of naming the alternatives.
final class ComparingPrimitive: TriggerPrimitive {
  let kind = PrimitiveKind.comparing
  let target: WatchTarget
  private var streak = StreakTracker()

  init(categoryID: String) {
    self.target = .category(categoryID)
  }

  func reset() { streak.clear() }

  func observe(_ o: Observation, at now: Date, policy: PrimitivePolicy) -> PrimitiveOutcome {
    let candidates = o.held(matching: target)
    guard candidates.count >= 2 else {
      streak.clear()
      return .idle
    }
    // The weakest of the pair, because a comparison is only as good as the
    // less certain half of it: one confident jar beside a guess is a pickup
    // being over-read, not two things being weighed against each other.
    let confidence = candidates.map(\.confidence).min() ?? 0
    guard confidence >= policy.minConfidence else {
      return .belowConfidence(confidence)
    }

    streak.add(confidence, at: now, window: policy.streakWindow)
    guard streak.count >= policy.consecutiveHits else {
      return .building(hits: streak.count, needed: policy.consecutiveHits)
    }
    return .fired(
      confidence: streak.best,
      hitCount: streak.count,
      evidence: TriggerEvidence(products: candidates.compactMap(\.productGuess), scene: o.scene))
  }
}

/// Stopped in front of a section.
///
/// The primitive that carries a trip where nobody picks anything up, which is
/// most of a real one. It is also the weakest evidence on the list and the most
/// frequent, which is why its defaults are the strictest.
final class DwellPrimitive: TriggerPrimitive {
  let kind = PrimitiveKind.dwell
  let target: WatchTarget
  private let categoryID: String
  private var streak = StreakTracker()

  init(categoryID: String) {
    self.categoryID = categoryID
    self.target = .category(categoryID)
  }

  func reset() { streak.clear() }

  func observe(_ o: Observation, at now: Date, policy: PrimitivePolicy) -> PrimitiveOutcome {
    guard let facing = o.facing,
          facing.categoryID.caseInsensitiveCompare(categoryID) == .orderedSame
    else {
      // Turning away ends the dwell. Unlike a pickup this happens constantly --
      // a head turn is not leaving the aisle -- which is what the streak window
      // is sized to absorb.
      streak.clear()
      return .idle
    }
    guard facing.confidence >= policy.minConfidence else {
      return .belowConfidence(facing.confidence)
    }

    streak.add(facing.confidence, at: now, window: policy.streakWindow)
    guard streak.count >= policy.consecutiveHits else {
      return .building(hits: streak.count, needed: policy.consecutiveHits)
    }
    return .fired(
      confidence: streak.best,
      hitCount: streak.count,
      evidence: TriggerEvidence(products: o.held.compactMap(\.productGuess), scene: o.scene))
  }
}
