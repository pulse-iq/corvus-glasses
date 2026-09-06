import Foundation

/// Tuning for how eagerly the watcher interrupts a shopper.
///
/// Defaults lean conservative throughout: a missed intercept costs one data
/// point, while a spurious one costs the participant's trust and contaminates
/// everything after it.
struct TriggerPolicy: Equatable {
  /// Per-primitive thresholds. Anything absent runs on that primitive's own
  /// default rather than a shared one -- a dwell and a pickup are not the same
  /// bet and should not share a confidence floor.
  var primitives: [PrimitiveKind: PrimitivePolicy]
  /// Quiet period after an intercept ends, so two pickups in a row do not
  /// become two back-to-back intercepts.
  var globalCooldown: TimeInterval = 90
  /// Safety valve: if an intercept never reports back (crash, dropped session),
  /// the watcher un-sticks itself instead of going silent for the rest of the
  /// trip.
  var maxInterceptDuration: TimeInterval = 120
  /// Hard ceiling on intercepts per run of the watcher.
  ///
  /// A ceiling, not a target: six good intercepts in a forty-minute shop is a
  /// successful trip and twelve is a hostile one, so this is where the watcher
  /// stops rather than where it aims. Cooldowns alone do not bound it, because
  /// they bound spacing rather than total.
  var maxInterceptsPerTrip: Int = 12

  init(
    primitives: [PrimitiveKind: PrimitivePolicy] = [:],
    globalCooldown: TimeInterval = 90,
    maxInterceptDuration: TimeInterval = 120,
    maxInterceptsPerTrip: Int = 12
  ) {
    self.primitives = primitives
    self.globalCooldown = globalCooldown
    self.maxInterceptDuration = maxInterceptDuration
    self.maxInterceptsPerTrip = maxInterceptsPerTrip
  }

  func policy(for kind: PrimitiveKind) -> PrimitivePolicy {
    primitives[kind] ?? .default(for: kind)
  }

  static let `default` = TriggerPolicy()
}

/// A decision to intercept, with the evidence that produced it.
struct Trigger: Equatable {
  /// Which primitive earned it. Recorded because the same product firing on
  /// `holding` and on `examining` are different research events, and the
  /// difference is invisible once the question has been asked.
  let primitive: PrimitiveKind
  let target: WatchTarget
  /// What the intercept is about, already resolved: nothing downstream of here
  /// needs to know whether a product or a section fired.
  let subject: InterceptSubject
  let firedAt: Date
  /// Highest confidence among the hits that formed the streak.
  let confidence: Double
  let hitCount: Int
  let evidence: TriggerEvidence
}

/// One primitive's progress towards firing. The debug panel's whole job during
/// tuning is showing these, because knowing *which* gate a pickup died at is
/// the difference between fixing the prompt and fixing the thresholds.
struct PrimitiveProgress: Equatable {
  let kind: PrimitiveKind
  let targetID: String
  let hits: Int
  let needed: Int
  /// Set when the frame matched the target but scored under its floor.
  let underConfidence: Double?

  var label: String {
    if let under = underConfidence {
      return String(format: "%@:%@:low %.2f", kind.rawValue, targetID, under)
    }
    return "\(kind.rawValue):\(targetID):\(hits)/\(needed)"
  }
}

/// Why a frame did or did not produce an intercept.
enum TriggerDecision: Equatable {
  case fired(Trigger)
  /// One or more primitives are partway there, or were held back by their
  /// confidence floor.
  case building([PrimitiveProgress])
  /// Nothing watched in this frame. `sawProduct` is what was in the wearer's
  /// hands instead, when there was something -- the number that says a
  /// watchlist is missing what people actually pick up.
  case quiet(sawProduct: String?)
  case targetCoolingDown(targetID: String, until: Date)
  case globallyLocked(until: Date?)
  case budgetSpent(used: Int, limit: Int)
}

/// Everything one frame produced.
///
/// `alsoFired` exists because a suppressed primitive is context rather than
/// noise: a dwell that lost to the pickup two seconds later is precisely what
/// makes the pickup's question a good one, and dropping it on the floor is how
/// that gets lost.
struct TriggerOutcome: Equatable {
  let decision: TriggerDecision
  let alsoFired: [Trigger]

  init(_ decision: TriggerDecision, alsoFired: [Trigger] = []) {
    self.decision = decision
    self.alsoFired = alsoFired
  }
}

/// Turns a stream of per-frame observations into intercept triggers.
///
/// Two jobs, kept apart on purpose. The primitives decide *whether* their own
/// moment happened; this decides whether anyone gets interrupted about it --
/// cooldowns, the intercept lock, the trip budget, and which of several
/// simultaneous moments wins. A primitive that knew about cooldowns could not
/// be reasoned about on its own.
///
/// Pure and clock-injected: every decision is a function of the observations it
/// has been shown and the timestamps it was given, so the whole policy is
/// testable without a camera, a network, or a wall clock.
final class TriggerStateMachine {
  private let study: Study
  private(set) var policy: TriggerPolicy

  /// Sorted once, at construction: highest priority first, and among equals the
  /// more specific target. Arbitration is then "the first one that fired".
  private let primitives: [TriggerPrimitive]

  private var lastTriggeredByTarget: [String: Date] = [:]
  /// Set while an intercept is in flight or its cooldown is running. nil means
  /// the watcher is free to fire.
  private var lockedUntil: Date?
  private var interceptStartedAt: Date?
  private(set) var interceptsFired = 0

  init(study: Study, policy: TriggerPolicy? = nil) {
    self.study = study
    self.policy = policy ?? study.policy
    self.primitives = Self.build(for: study).sorted {
      ($0.kind.priority, $0.target.specificity) > ($1.kind.priority, $1.target.specificity)
    }
  }

  /// One primitive per (kind, target) the entry asks for.
  ///
  /// An entry that names none gets everything its target can support: items the
  /// two hand primitives, sections those plus the two that only make sense
  /// against a range. A study that names both `sourdough` and the `bread`
  /// section watches for both, and the specificity tie-break decides which one
  /// speaks when a sourdough loaf is picked up.
  private static func build(for study: Study) -> [TriggerPrimitive] {
    var made: [TriggerPrimitive] = []
    for item in study.items {
      let kinds = item.primitives.isEmpty
        ? PrimitiveKind.applicable(toItem: true) : item.primitives
      made += kinds.compactMap { make($0, for: .item(item.id)) }
    }
    for category in study.categories {
      let kinds = category.primitives.isEmpty
        ? PrimitiveKind.applicable(toItem: false) : category.primitives
      made += kinds.compactMap { make($0, for: .category(category.id)) }
    }
    return made
  }

  private static func make(_ kind: PrimitiveKind, for target: WatchTarget) -> TriggerPrimitive? {
    switch (kind, target) {
    case (.holding, _), (.examining, _):
      return HeldPrimitive(kind: kind, target: target)
    case (.comparing, .category(let id)):
      return ComparingPrimitive(categoryID: id)
    case (.dwell, .category(let id)):
      return DwellPrimitive(categoryID: id)
    // Unreachable via a decoded study, which rejects these outright; the
    // compiler cannot know that, and silently dropping beats a crash here.
    case (.comparing, .item), (.dwell, .item):
      return nil
    }
  }

  /// Feed one observation. Returns what the machine decided and why.
  func observe(_ o: Observation, at now: Date) -> TriggerOutcome {
    // An intercept that overran its safety ceiling releases the lock outright;
    // otherwise a dropped intercept session would silence the rest of the trip.
    // Deliberately not endIntercept(): that would stack a fresh global cooldown
    // on top of the timeout just served, and the watcher has already been quiet
    // for maxInterceptDuration. The per-target cooldown still guards whatever
    // the lost intercept was about.
    if let started = interceptStartedAt, now.timeIntervalSince(started) > policy.maxInterceptDuration {
      interceptStartedAt = nil
      lockedUntil = nil
    }

    if let until = lockedUntil {
      if interceptStartedAt != nil || now < until {
        // Nothing accumulates while the floor is taken. A streak built during
        // an intercept describes a moment the wearer has already finished.
        resetPrimitives()
        return TriggerOutcome(.globallyLocked(until: interceptStartedAt == nil ? until : nil))
      }
      lockedUntil = nil
    }

    if interceptsFired >= policy.maxInterceptsPerTrip {
      resetPrimitives()
      return TriggerOutcome(
        .budgetSpent(used: interceptsFired, limit: policy.maxInterceptsPerTrip))
    }

    var fired: [(TriggerPrimitive, Double, Int, TriggerEvidence)] = []
    var progress: [PrimitiveProgress] = []
    var cooling: [(target: WatchTarget, until: Date)] = []

    for primitive in primitives {
      let p = policy.policy(for: primitive.kind)
      guard p.enabled else { continue }

      let key = primitive.target.id
      if let last = lastTriggeredByTarget[key] {
        let ready = last.addingTimeInterval(p.cooldown)
        if now < ready {
          // Nothing builds during a cooldown, so the primitive cannot fire the
          // instant one expires on the strength of frames from inside it.
          primitive.reset()
          if o.mentions(primitive.target) {
            cooling.append((primitive.target, ready))
          }
          continue
        }
      }

      switch primitive.observe(o, at: now, policy: p) {
      case .idle:
        continue
      case .belowConfidence(let c):
        progress.append(.init(
          kind: primitive.kind, targetID: primitive.target.rawID,
          hits: 0, needed: p.consecutiveHits, underConfidence: c))
      case .building(let hits, let needed):
        progress.append(.init(
          kind: primitive.kind, targetID: primitive.target.rawID,
          hits: hits, needed: needed, underConfidence: nil))
      case .fired(let confidence, let hitCount, let evidence):
        fired.append((primitive, confidence, hitCount, evidence))
      }
    }

    if !fired.isEmpty {
      // The list is pre-sorted, so the first to fire is the winner and the rest
      // are recorded as context rather than dropped.
      let triggers = fired.compactMap { entry -> Trigger? in
        guard let subject = study.subject(
          for: entry.0.target, kind: entry.0.kind, evidence: entry.3)
        else { return nil }
        return Trigger(
          primitive: entry.0.kind,
          target: entry.0.target,
          subject: subject,
          firedAt: now,
          confidence: entry.1,
          hitCount: entry.2,
          evidence: entry.3)
      }
      if let winner = triggers.first {
        // A pickup and the section it came from are one moment, not two. Cool
        // both, or the intercept about the olive oil is followed straight away
        // by an intercept about the oils, which to the wearer is being asked
        // the same question twice.
        for key in relatedTargets(of: winner.target) {
          lastTriggeredByTarget[key] = now
        }
        interceptsFired += 1
        // Hold the lock open-ended: the global cooldown should run from when
        // the intercept *ends*, not when it starts, or a 45s intercept eats
        // most of it.
        interceptStartedAt = now
        lockedUntil = now.addingTimeInterval(policy.maxInterceptDuration)
        resetPrimitives()
        return TriggerOutcome(.fired(winner), alsoFired: Array(triggers.dropFirst()))
      }
    }

    if !progress.isEmpty {
      return TriggerOutcome(.building(progress))
    }
    // Report the most specific thing being held back rather than the
    // highest-priority one: "cereal is cooling down" is what someone tuning
    // this needs to read, and "its section is too" follows from it.
    if let held = cooling.max(by: { $0.target.specificity < $1.target.specificity }) {
      return TriggerOutcome(
        .targetCoolingDown(targetID: held.target.rawID, until: held.until))
    }
    return TriggerOutcome(.quiet(sawProduct: o.unmatched.first?.productGuess))
  }

  /// The interceptor reports back here. Starts the global cooldown.
  func endIntercept(at now: Date) {
    interceptStartedAt = nil
    lockedUntil = now.addingTimeInterval(policy.globalCooldown)
  }

  func update(policy newPolicy: TriggerPolicy) {
    policy = newPolicy
  }

  /// Full reset between participants or test runs.
  func reset() {
    resetPrimitives()
    lastTriggeredByTarget.removeAll()
    lockedUntil = nil
    interceptStartedAt = nil
    interceptsFired = 0
  }

  func clearEvidence() { resetPrimitives() }

  private func resetPrimitives() {
    for primitive in primitives { primitive.reset() }
  }

  /// The target itself plus everything that describes the same physical thing:
  /// an item's section, or a section's named members.
  private func relatedTargets(of target: WatchTarget) -> [String] {
    var keys = [target.id]
    switch target {
    case .item(let id):
      if let categoryID = Watchlist.item(withID: id, in: study.items)?.categoryID {
        keys.append(WatchTarget.category(categoryID).id)
      }
    case .category(let id):
      keys += study.items
        .filter { $0.categoryID?.caseInsensitiveCompare(id) == .orderedSame }
        .map { WatchTarget.item($0.id).id }
    }
    return keys
  }
}

// MARK: - Resolving a target into something an intercept can open with

extension Study {
  /// Turns a fired primitive into the subject of an intercept.
  ///
  /// This is where a target stops being a slug and becomes a first line. The
  /// situation sentence matters as much as the question: an opener written for
  /// a pickup, asked of someone who has not touched anything, is wrong in a way
  /// the participant notices immediately.
  func subject(
    for target: WatchTarget, kind: PrimitiveKind, evidence: TriggerEvidence
  ) -> InterceptSubject? {
    let name: String
    let questions: QuestionSet
    let followUps: [String]

    switch target {
    case .item(let id):
      guard let item = Watchlist.item(withID: id, in: items) else { return nil }
      name = item.displayName
      questions = item.questions
      followUps = item.followUps
    case .category(let id):
      guard let category = Watchlist.category(withID: id, in: categories) else { return nil }
      name = category.displayName
      questions = category.questions
      followUps = []
    }

    return InterceptSubject(
      targetID: target.rawID,
      displayName: name,
      situation: Self.situation(kind: kind, target: target, name: name, evidence: evidence),
      question: questions.question(for: kind),
      followUps: followUps)
  }

  /// A whole sentence, so the intercept prompts can drop it in without
  /// reconciling tense or subject with their own surrounding text.
  private static func situation(
    kind: PrimitiveKind, target: WatchTarget, name: String, evidence: TriggerEvidence
  ) -> String {
    let what = held(target, name, evidence)
    switch kind {
    case .holding:
      return "They have just picked up \(what)."
    case .examining:
      return "They are holding \(what) up close and reading the label."
    case .comparing:
      let pair = evidence.products.prefix(2)
      if pair.count == 2 {
        return "They are holding \(pair[pair.startIndex]) and "
          + "\(pair[pair.index(after: pair.startIndex)]) at the same time, weighing them up."
      }
      return "They are holding two different \(name) at the same time, weighing them up."
    case .dwell:
      return "They have been standing in front of the \(name), looking at what is there, "
        + "without picking anything up yet."
    }
  }

  /// Names the thing in someone's hand.
  ///
  /// A section is not a product, so it cannot go straight into "picked up ..."
  /// -- "picked up the yogurts" is wrong in a way a participant hears. When the
  /// model gave its own description, that is the best name available either
  /// way; when it did not, an item falls back to its label and a section has to
  /// say it was something from that section.
  private static func held(
    _ target: WatchTarget, _ name: String, _ evidence: TriggerEvidence
  ) -> String {
    guard let seen = evidence.products.first, !seen.isEmpty else {
      switch target {
      case .item: return name
      case .category: return "something from the \(name)"
      }
    }
    switch target {
    case .item:
      // Prefer the model's own words over the study's label: the wearer is
      // holding a specific bottle, and "the olive oil" is what a survey would
      // have called it.
      return seen.localizedCaseInsensitiveContains(name) ? seen : "\(seen) (\(name))"
    case .category:
      return seen
    }
  }
}
