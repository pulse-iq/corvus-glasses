import XCTest

@testable import CameraAccess

/// The trigger policy is the part of the watcher that decides whether a shopper
/// gets interrupted, so it is the part worth pinning down without a camera.
/// Every test drives the machine with explicit timestamps.
final class CorvusTriggerTests: XCTestCase {

  private let study = Study(
    id: "test",
    name: "Test",
    items: [
      WatchItem(id: "cereal", displayName: "breakfast cereal", question: "Why that one?",
                categoryID: "breakfast"),
      WatchItem(id: "coffee", displayName: "coffee", question: "What were you after?"),
    ],
    categories: [
      WatchCategory(id: "breakfast", displayName: "breakfast cereal",
                    question: "What are you weighing up?"),
    ])

  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Fixtures

  private func held(
    _ id: String?, category: String? = nil, examining: Bool = false, _ confidence: Double = 0.9
  ) -> HeldProduct {
    HeldProduct(
      itemID: id, categoryID: category, productGuess: id.map { "a \($0)" },
      examining: examining, confidence: confidence)
  }

  /// One product in hand. The category rides along, exactly as the parser fills
  /// it in from the item's own membership.
  private func holding(_ id: String, examining: Bool = false, _ confidence: Double = 0.9)
    -> Observation
  {
    let category = Watchlist.item(withID: id, in: study.items)?.categoryID
    return Observation(
      held: [held(id, category: category, examining: examining, confidence)], scene: .aisle)
  }

  private func facing(_ categoryID: String, _ confidence: Double = 0.9) -> Observation {
    Observation(facing: ShelfFacing(categoryID: categoryID, confidence: confidence), scene: .aisle)
  }

  private func machine(_ policy: TriggerPolicy? = nil) -> TriggerStateMachine {
    TriggerStateMachine(study: study, policy: policy)
  }

  private func fired(_ outcome: TriggerOutcome, file: StaticString = #filePath, line: UInt = #line)
    -> Trigger?
  {
    guard case .fired(let trigger) = outcome.decision else {
      XCTFail("expected a trigger, got \(outcome.decision)", file: file, line: line)
      return nil
    }
    return trigger
  }

  private func progress(
    _ outcome: TriggerOutcome, _ kind: PrimitiveKind, _ targetID: String
  ) -> PrimitiveProgress? {
    guard case .building(let entries) = outcome.decision else { return nil }
    return entries.first { $0.kind == kind && $0.targetID == targetID }
  }

  // MARK: - Streak

  func testSingleHitDoesNotFire() {
    let m = machine()
    let outcome = m.observe(holding("cereal"), at: t0)
    guard let p = progress(outcome, .holding, "cereal") else {
      return XCTFail("expected a building streak, got \(outcome.decision)")
    }
    XCTAssertEqual(p.hits, 1)
    XCTAssertEqual(p.needed, 2)
  }

  func testTwoConsecutiveHitsFire() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    let trigger = fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1)))
    XCTAssertEqual(trigger?.subject.targetID, "cereal")
    XCTAssertEqual(trigger?.primitive, .holding)
    XCTAssertEqual(trigger?.hitCount, 2)
  }

  func testHitsOutsideTheStreakWindowDoNotAccumulate() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    // Far enough apart that the first hit has aged out: this is a glance, not
    // a pickup, and must not fire.
    let outcome = m.observe(holding("cereal"), at: t0.addingTimeInterval(30))
    XCTAssertEqual(progress(outcome, .holding, "cereal")?.hits, 1)
  }

  func testABlurredFrameBetweenTwoGoodOnesStillFires() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    // A dropped/low-confidence frame must not reset a streak -- misses age out
    // rather than clearing, which is the whole point of the time window.
    _ = m.observe(holding("cereal", 0.2), at: t0.addingTimeInterval(1))
    XCTAssertNotNil(fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(2))))
  }

  func testPuttingTheProductDownClearsTheStreak() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    _ = m.observe(.empty, at: t0.addingTimeInterval(1))
    let outcome = m.observe(holding("cereal"), at: t0.addingTimeInterval(2))
    XCTAssertEqual(progress(outcome, .holding, "cereal")?.hits, 1)
  }

  func testSwitchingProductRestartsTheStreak() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    let outcome = m.observe(holding("coffee"), at: t0.addingTimeInterval(1))
    XCTAssertEqual(progress(outcome, .holding, "coffee")?.hits, 1)
    XCTAssertNil(progress(outcome, .holding, "cereal"))
  }

  // MARK: - Gates

  func testLowConfidenceNeverCounts() {
    let m = machine()
    _ = m.observe(holding("cereal", 0.3), at: t0)
    let outcome = m.observe(holding("cereal", 0.3), at: t0.addingTimeInterval(1))
    XCTAssertEqual(progress(outcome, .holding, "cereal")?.underConfidence, 0.3)
  }

  func testOffWatchlistProductIsReportedButDoesNotFire() {
    let m = machine()
    let o = Observation(held: [HeldProduct(productGuess: "shampoo", confidence: 0.95)])
    guard case .quiet(let guess) = m.observe(o, at: t0).decision else {
      return XCTFail("expected a quiet frame")
    }
    XCTAssertEqual(guess, "shampoo")
  }

  // MARK: - Examining

  func testExaminingBeatsHoldingOnTheSameFrame() {
    let m = machine()
    _ = m.observe(holding("cereal", examining: true), at: t0)
    let trigger = fired(m.observe(holding("cereal", examining: true), at: t0.addingTimeInterval(1)))
    // Both primitives are satisfied; reading the label is the more specific
    // moment and the one worth asking about.
    XCTAssertEqual(trigger?.primitive, .examining)
  }

  func testCarryingSomethingIsNotExamining() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    let trigger = fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1)))
    XCTAssertEqual(trigger?.primitive, .holding)
  }

  func testTheLosingPrimitiveIsStillReported() {
    let m = machine()
    _ = m.observe(holding("cereal", examining: true), at: t0)
    let outcome = m.observe(holding("cereal", examining: true), at: t0.addingTimeInterval(1))
    // A suppressed primitive is context, not noise: it is what makes the
    // winner's question a good one, so it must survive arbitration.
    XCTAssertTrue(outcome.alsoFired.contains { $0.primitive == .holding })
  }

  // MARK: - Categories

  func testAnItemBeatsItsOwnSectionOnTheSameFrame() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    let trigger = fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1)))
    XCTAssertEqual(trigger?.target, .item("cereal"))
  }

  func testAnUnlistedProductStillFiresItsSection() {
    let m = machine()
    // Exactly what a real shop produces: a yogurt nobody enumerated, in a
    // section that was.
    let o = Observation(
      held: [HeldProduct(categoryID: "breakfast", productGuess: "own-brand bran flakes",
                         confidence: 0.8)],
      scene: .aisle)
    _ = m.observe(o, at: t0)
    let trigger = fired(m.observe(o, at: t0.addingTimeInterval(1)))
    XCTAssertEqual(trigger?.target, .category("breakfast"))
    XCTAssertEqual(trigger?.subject.question, "What are you weighing up?")
  }

  func testComparingBeatsHoldingWhenTwoOfASectionAreHeld() {
    let m = machine()
    let o = Observation(
      held: [held("cereal", category: "breakfast"),
             HeldProduct(categoryID: "breakfast", productGuess: "muesli", confidence: 0.8)],
      scene: .aisle)
    _ = m.observe(o, at: t0)
    let trigger = fired(m.observe(o, at: t0.addingTimeInterval(1)))
    XCTAssertEqual(trigger?.primitive, .comparing)
    XCTAssertEqual(trigger?.evidence.products.count, 2)
  }

  func testComparingTakesTheWeakerOfThePair() {
    // One confident jar beside a guess is a pickup being over-read, not two
    // things being weighed up, so the floor applies to the weaker half.
    let m = machine()
    let o = Observation(
      held: [held("cereal", category: "breakfast", 0.95),
             HeldProduct(categoryID: "breakfast", productGuess: "muesli", confidence: 0.2)],
      scene: .aisle)
    let first = m.observe(o, at: t0)
    XCTAssertEqual(progress(first, .comparing, "breakfast")?.underConfidence, 0.2)
    // And the frame resolves as the pickup it actually is.
    XCTAssertEqual(fired(m.observe(o, at: t0.addingTimeInterval(1)))?.primitive, .holding)
  }

  // MARK: - Dwell

  func testDwellNeedsSustainedFacing() {
    let m = machine()
    // Four frames of standing there is not yet enough; the fifth is.
    for i in 0..<4 {
      let outcome = m.observe(facing("breakfast"), at: t0.addingTimeInterval(Double(i) * 1.5))
      XCTAssertEqual(progress(outcome, .dwell, "breakfast")?.hits, i + 1)
    }
    let trigger = fired(m.observe(facing("breakfast"), at: t0.addingTimeInterval(6)))
    XCTAssertEqual(trigger?.primitive, .dwell)
    XCTAssertEqual(trigger?.target, .category("breakfast"))
  }

  func testTurningAwayEndsTheDwell() {
    let m = machine()
    for i in 0..<4 {
      _ = m.observe(facing("breakfast"), at: t0.addingTimeInterval(Double(i) * 1.5))
    }
    _ = m.observe(.empty, at: t0.addingTimeInterval(6))
    let outcome = m.observe(facing("breakfast"), at: t0.addingTimeInterval(7.5))
    XCTAssertEqual(progress(outcome, .dwell, "breakfast")?.hits, 1)
  }

  func testAPickupBeatsADwellThatIsAlreadyRunning() {
    let m = machine()
    // Standing at the shelf, then reaching in. The pickup is the better moment,
    // and the dwell it interrupted is recorded rather than lost.
    for i in 0..<3 {
      _ = m.observe(facing("breakfast"), at: t0.addingTimeInterval(Double(i) * 1.5))
    }
    let both = Observation(
      held: [held("cereal", category: "breakfast")],
      facing: ShelfFacing(categoryID: "breakfast", confidence: 0.9),
      scene: .aisle)
    _ = m.observe(both, at: t0.addingTimeInterval(4.5))
    let outcome = m.observe(both, at: t0.addingTimeInterval(6))
    XCTAssertEqual(fired(outcome)?.primitive, .holding)
    XCTAssertTrue(outcome.alsoFired.contains { $0.primitive == .dwell })
  }

  // MARK: - Cooldowns and budget

  func testReadinessLossClearsEvidenceButPreservesEarnedCooldown() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    m.clearEvidence()
    if case .fired = m.observe(holding("cereal"), at: t0.addingTimeInterval(1)).decision { XCTFail("Stale evidence triggered an interview") }
    XCTAssertNotNil(fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(2))))
    m.endIntercept(at: t0.addingTimeInterval(30))
    m.clearEvidence()
    guard case .targetCoolingDown = m.observe(holding("cereal"), at: t0.addingTimeInterval(200)).decision else {
      return XCTFail("Readiness loss erased a cooldown")
    }
  }

  func testTheSameTargetCannotRetriggerDuringItsCooldown() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    XCTAssertNotNil(fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1))))
    m.endIntercept(at: t0.addingTimeInterval(30))

    // Past the global cooldown, still inside the item's own.
    let later = t0.addingTimeInterval(200)
    _ = m.observe(holding("cereal"), at: later)
    guard case .targetCoolingDown(let id, _) = m.observe(holding("cereal"), at: later.addingTimeInterval(1)).decision
    else {
      return XCTFail("expected the item to still be cooling down")
    }
    XCTAssertEqual(id, "cereal")
  }

  func testFiringAboutAnItemAlsoCoolsTheSectionItBelongsTo() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    XCTAssertNotNil(fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1))))
    m.endIntercept(at: t0.addingTimeInterval(30))

    // Past the global cooldown, standing at the shelf the cereal came from.
    // Asking about the section now is asking the same question twice.
    let later = t0.addingTimeInterval(200)
    for i in 0..<5 {
      _ = m.observe(facing("breakfast"), at: later.addingTimeInterval(Double(i) * 1.5))
    }
    guard case .targetCoolingDown(let id, _) =
      m.observe(facing("breakfast"), at: later.addingTimeInterval(9)).decision
    else {
      return XCTFail("expected the section to be cooling down with its item")
    }
    XCTAssertEqual(id, "breakfast")
  }

  func testADifferentItemCanFireAfterTheGlobalCooldown() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    _ = m.observe(holding("cereal"), at: t0.addingTimeInterval(1))
    m.endIntercept(at: t0.addingTimeInterval(30))

    let later = t0.addingTimeInterval(200)
    _ = m.observe(holding("coffee"), at: later)
    XCTAssertEqual(fired(m.observe(holding("coffee"), at: later.addingTimeInterval(1)))?.subject.targetID, "coffee")
  }

  func testNothingFiresWhileAnInterceptHasTheFloor() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    XCTAssertNotNil(fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1))))
    // No endIntercept: the intercept is still running.
    guard case .globallyLocked = m.observe(holding("coffee"), at: t0.addingTimeInterval(5)).decision
    else {
      return XCTFail("expected the machine to be locked")
    }
  }

  func testAStreakDoesNotSurviveAnIntercept() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    _ = m.observe(holding("cereal"), at: t0.addingTimeInterval(1))
    // Frames arriving during the intercept describe a moment the wearer has
    // already finished; they must not count towards the next trigger.
    _ = m.observe(holding("coffee"), at: t0.addingTimeInterval(2))
    _ = m.observe(holding("coffee"), at: t0.addingTimeInterval(3))
    m.endIntercept(at: t0.addingTimeInterval(4))

    let after = t0.addingTimeInterval(200)
    XCTAssertEqual(progress(m.observe(holding("coffee"), at: after), .holding, "coffee")?.hits, 1)
  }

  func testALostInterceptReleasesTheLock() {
    let m = machine()
    _ = m.observe(holding("cereal"), at: t0)
    XCTAssertNotNil(fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1))))
    // endIntercept never arrives. Past the safety ceiling the watcher un-sticks
    // itself rather than going silent for the rest of the trip.
    let after = t0.addingTimeInterval(TriggerPolicy.default.maxInterceptDuration + 10)
    _ = m.observe(holding("coffee"), at: after)
    XCTAssertNotNil(fired(m.observe(holding("coffee"), at: after.addingTimeInterval(1))))
  }

  func testTheTripBudgetIsAHardCeiling() {
    var policy = TriggerPolicy.default
    policy.maxInterceptsPerTrip = 1
    let m = machine(policy)
    _ = m.observe(holding("cereal"), at: t0)
    XCTAssertNotNil(fired(m.observe(holding("cereal"), at: t0.addingTimeInterval(1))))
    m.endIntercept(at: t0.addingTimeInterval(30))

    let later = t0.addingTimeInterval(500)
    _ = m.observe(holding("coffee"), at: later)
    guard case .budgetSpent(let used, let limit) = m.observe(holding("coffee"), at: later.addingTimeInterval(1)).decision
    else {
      return XCTFail("expected the trip budget to stop the watcher")
    }
    XCTAssertEqual(used, 1)
    XCTAssertEqual(limit, 1)
  }

  func testDisablingAPrimitiveSilencesIt() {
    var policy = TriggerPolicy.default
    var dwell = PrimitivePolicy.default(for: .dwell)
    dwell.enabled = false
    policy.primitives[.dwell] = dwell
    let m = machine(policy)
    for i in 0..<10 {
      _ = m.observe(facing("breakfast"), at: t0.addingTimeInterval(Double(i) * 1.5))
    }
    guard case .quiet = m.observe(facing("breakfast"), at: t0.addingTimeInterval(20)).decision else {
      return XCTFail("a disabled primitive must never fire or report progress")
    }
  }

  func testANarrowedItemDoesNotFireTheDroppedPrimitive() {
    let narrowed = Study(
      id: "narrow", name: "Narrow",
      items: [WatchItem(id: "cereal", displayName: "breakfast cereal",
                        question: "Why that one?", primitives: [.holding])])
    let m = TriggerStateMachine(study: narrowed)
    // Reading the label would normally win on priority; with examining dropped
    // the pickup is what is left, and it still fires alone.
    _ = m.observe(holding("cereal", examining: true), at: t0)
    let outcome = m.observe(holding("cereal", examining: true), at: t0.addingTimeInterval(1))
    XCTAssertEqual(fired(outcome)?.primitive, .holding)
    XCTAssertTrue(outcome.alsoFired.isEmpty)
  }

  // MARK: - Subjects

  func testTheSituationSentenceMatchesThePrimitive() {
    let m = machine()
    _ = m.observe(holding("cereal", examining: true), at: t0)
    let trigger = fired(m.observe(holding("cereal", examining: true), at: t0.addingTimeInterval(1)))
    XCTAssertEqual(trigger?.subject.situation.hasPrefix("They are holding"), true)
    XCTAssertTrue(trigger?.subject.situation.contains("reading the label") == true)
  }

  func testASectionIsNeverNamedAsIfItWereAProduct() {
    let m = machine()
    // A product the study does not name, in a section it does. "Picked up the
    // breakfast cereal section" is wrong in a way a participant hears, so a
    // section hit is described by what the model actually saw.
    let o = Observation(
      held: [HeldProduct(categoryID: "breakfast", productGuess: "own-brand bran flakes",
                         confidence: 0.8)],
      scene: .aisle)
    _ = m.observe(o, at: t0)
    let trigger = fired(m.observe(o, at: t0.addingTimeInterval(1)))
    XCTAssertEqual(trigger?.subject.situation, "They have just picked up own-brand bran flakes.")
  }

  func testASectionHitWithNoDescriptionSaysWhereItCameFrom() {
    let m = machine()
    let o = Observation(
      held: [HeldProduct(categoryID: "breakfast", confidence: 0.8)], scene: .aisle)
    _ = m.observe(o, at: t0)
    let trigger = fired(m.observe(o, at: t0.addingTimeInterval(1)))
    XCTAssertEqual(
      trigger?.subject.situation,
      "They have just picked up something from the breakfast cereal.")
  }

  func testADwellSubjectDoesNotClaimAnythingWasPickedUp() {
    let m = machine()
    for i in 0..<4 {
      _ = m.observe(facing("breakfast"), at: t0.addingTimeInterval(Double(i) * 1.5))
    }
    let trigger = fired(m.observe(facing("breakfast"), at: t0.addingTimeInterval(6)))
    // An opener written for a pickup, asked of someone who has not touched
    // anything, is wrong in a way the participant notices immediately.
    XCTAssertFalse(trigger?.subject.situation.contains("picked up") == true)
  }
}

/// The study file format, which is edited by hand on a phone and therefore gets
/// its own tests. The failure that matters here is the silent one: an override
/// that stops applying without anything saying so.
final class CorvusStudyDecodingTests: XCTestCase {

  private func decode(_ json: String) throws -> Study {
    try JSONDecoder().decode(Study.self, from: Data(json.utf8))
  }

  private let minimal = """
    {"id": "s", "name": "S", "items": [
      {"id": "a", "displayName": "a thing", "question": "why?"}]
    """

  func testAStringQuestionStillDecodes() throws {
    let study = try decode(minimal + "}")
    XCTAssertEqual(study.items[0].questions.question(for: .holding), "why?")
    XCTAssertEqual(study.items[0].questions.question(for: .dwell), "why?")
  }

  func testPerPrimitiveQuestionsFallBackToTheDefault() throws {
    let study = try decode("""
      {"id": "s", "name": "S", "items": [
        {"id": "a", "displayName": "a thing",
         "question": {"default": "why?", "examining": "what are you checking?"}}]}
      """)
    XCTAssertEqual(study.items[0].questions.question(for: .examining), "what are you checking?")
    XCTAssertEqual(study.items[0].questions.question(for: .holding), "why?")
  }

  func testAQuestionKeyedBySomethingThatIsNotAPrimitiveIsRejected() {
    // Otherwise it is a question that is simply never asked, and never
    // complained about.
    XCTAssertThrowsError(try decode("""
      {"id": "s", "name": "S", "items": [
        {"id": "a", "displayName": "a thing", "question": {"default": "why?", "hodling": "typo"}}]}
      """))
  }

  func testTheFlatPolicyShapeStillMeansWhatItMeant() throws {
    let study = try decode(minimal + """
      , "triggerPolicy": {"minConfidence": 0.8, "consecutiveHits": 3, "streakWindow": 9,
                          "perItemCooldown": 30, "globalCooldown": 15}}
      """)
    let holding = study.policy.policy(for: .holding)
    XCTAssertEqual(holding.minConfidence, 0.8)
    XCTAssertEqual(holding.consecutiveHits, 3)
    XCTAssertEqual(holding.streakWindow, 9)
    XCTAssertEqual(holding.cooldown, 30)
    XCTAssertEqual(study.policy.globalCooldown, 15)
    // Untouched primitives keep their own defaults rather than inheriting the
    // one that happened to be written in the flat shape.
    XCTAssertEqual(study.policy.policy(for: .dwell), .default(for: .dwell))
  }

  func testAnEntryCanNarrowItsPrimitives() throws {
    let study = try decode("""
      {"id": "s", "name": "S",
       "items": [{"id": "a", "displayName": "a thing", "question": "why?",
                  "primitives": ["holding"]}],
       "categories": [{"id": "c", "displayName": "some things", "question": "well?",
                       "primitives": ["dwell", "holding"]}]}
      """)
    XCTAssertEqual(study.items[0].primitives, [.holding])
    XCTAssertEqual(study.categories[0].primitives, [.dwell, .holding])
  }

  func testSayingNothingMeansEverythingTheTargetSupports() throws {
    let study = try decode(minimal + "}")
    // Empty is the signal to fall back, so a study file written before the
    // field existed keeps behaving exactly as it did.
    XCTAssertTrue(study.items[0].primitives.isEmpty)
    XCTAssertEqual(PrimitiveKind.applicable(toItem: true), [.examining, .holding])
  }

  func testAPrimitiveThatCannotTargetAProductIsRejected() {
    // You cannot stand in front of one jar. Loud beats silently dropping it.
    XCTAssertThrowsError(try decode("""
      {"id": "s", "name": "S", "items": [
        {"id": "a", "displayName": "a thing", "question": "why?", "primitives": ["dwell"]}]}
      """))
  }

  func testAnUnknownPrimitiveNameOnAnEntryIsRejected() {
    XCTAssertThrowsError(try decode("""
      {"id": "s", "name": "S", "items": [
        {"id": "a", "displayName": "a thing", "question": "why?", "primitives": ["hodling"]}]}
      """))
  }

  func testAStudyWithNoSectionsStillLoads() throws {
    let study = try decode(minimal + "}")
    XCTAssertTrue(study.categories.isEmpty)
    XCTAssertEqual(study.items.count, 1)
  }

  func testAPartialPrimitiveOverrideKeepsTheOtherThresholds() throws {
    let study = try decode(minimal + """
      , "triggerPolicy": {"primitives": {"dwell": {"cooldown": 60}}}}
      """)
    let dwell = study.policy.policy(for: .dwell)
    XCTAssertEqual(dwell.cooldown, 60)
    XCTAssertEqual(dwell.consecutiveHits, PrimitivePolicy.default(for: .dwell).consecutiveHits)
  }

  func testAnUnknownPolicyKeyIsAnErrorRatherThanASilentDefault() {
    // The whole point: rename a field and every study that overrode it goes on
    // parsing cleanly while the override stops applying. Loud beats quiet.
    XCTAssertThrowsError(try decode(minimal + """
      , "triggerPolicy": {"perItemCooldwn": 30}}
      """))
  }

  func testAnUnknownPrimitiveNameIsAnError() {
    XCTAssertThrowsError(try decode(minimal + """
      , "triggerPolicy": {"primitives": {"lingering": {"cooldown": 60}}}}
      """))
  }

  func testShippedStudiesDecode() throws {
    // The files that actually run. A packaging mistake here is invisible until
    // a trip produces nothing.
    for name in ["grocery-pilot", "kitchen-dev"] {
      guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        ?? Bundle.main.url(forResource: name, withExtension: "json")
      else { continue }
      let study = try JSONDecoder().decode(Study.self, from: Data(contentsOf: url))
      XCTAssertFalse(study.items.isEmpty, "\(name) has no items")
      for item in study.items where item.categoryID != nil {
        XCTAssertNotNil(
          Watchlist.category(withID: item.categoryID!, in: study.categories),
          "\(name): item \(item.id) points at a section that does not exist")
      }
    }
  }
}
