import XCTest

@testable import CameraAccess

/// The trigger policy is the part of Stage 1 that decides whether a shopper
/// gets interrupted, so it is the part worth pinning down without a camera.
/// Every test drives the machine with explicit timestamps.
final class CorvusTriggerTests: XCTestCase {

  private let items = [
    WatchItem(id: "cereal", displayName: "breakfast cereal", question: "Why that one?"),
    WatchItem(id: "coffee", displayName: "coffee", question: "What were you after?"),
  ]

  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func hit(_ id: String, _ confidence: Double = 0.9) -> Detection {
    Detection(holding: true, itemID: id, productGuess: nil, confidence: confidence)
  }

  private func machine(_ policy: TriggerPolicy = .default) -> TriggerStateMachine {
    TriggerStateMachine(watchlist: items, policy: policy)
  }

  // MARK: - Streak

  func testSingleHitDoesNotFire() {
    let m = machine()
    let decision = m.observe(hit("cereal"), at: t0)
    guard case .buildingStreak(_, let hits, let needed) = decision else {
      return XCTFail("expected a building streak, got \(decision)")
    }
    XCTAssertEqual(hits, 1)
    XCTAssertEqual(needed, 2)
  }

  func testTwoConsecutiveHitsFire() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    guard case .fired(let trigger) = m.observe(hit("cereal"), at: t0.addingTimeInterval(1)) else {
      return XCTFail("expected a trigger")
    }
    XCTAssertEqual(trigger.item.id, "cereal")
    XCTAssertEqual(trigger.hitCount, 2)
  }

  func testHitsOutsideTheStreakWindowDoNotAccumulate() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    // Far enough apart that the first hit has aged out: this is a glance, not
    // a pickup, and must not fire.
    let decision = m.observe(hit("cereal"), at: t0.addingTimeInterval(30))
    guard case .buildingStreak(_, let hits, _) = decision else {
      return XCTFail("expected a rebuilt streak, got \(decision)")
    }
    XCTAssertEqual(hits, 1)
  }

  func testABlurredFrameBetweenTwoGoodOnesStillFires() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    // A dropped/low-confidence frame must not reset a streak -- misses age out
    // rather than clearing, which is the whole point of the time window.
    _ = m.observe(hit("cereal", 0.2), at: t0.addingTimeInterval(1))
    guard case .fired = m.observe(hit("cereal"), at: t0.addingTimeInterval(2)) else {
      return XCTFail("expected a trigger despite the blurred frame")
    }
  }

  func testPuttingTheProductDownClearsTheStreak() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    _ = m.observe(Detection.empty, at: t0.addingTimeInterval(1))
    let decision = m.observe(hit("cereal"), at: t0.addingTimeInterval(2))
    guard case .buildingStreak(_, let hits, _) = decision else {
      return XCTFail("expected the streak to restart, got \(decision)")
    }
    XCTAssertEqual(hits, 1)
  }

  func testSwitchingProductRestartsTheStreak() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    let decision = m.observe(hit("coffee"), at: t0.addingTimeInterval(1))
    guard case .buildingStreak(let id, let hits, _) = decision else {
      return XCTFail("expected a new streak, got \(decision)")
    }
    XCTAssertEqual(id, "coffee")
    XCTAssertEqual(hits, 1)
  }

  // MARK: - Gates

  func testLowConfidenceNeverCounts() {
    let m = machine()
    _ = m.observe(hit("cereal", 0.3), at: t0)
    guard case .belowConfidence = m.observe(hit("cereal", 0.3), at: t0.addingTimeInterval(1)) else {
      return XCTFail("expected low-confidence rejection")
    }
  }

  func testOffWatchlistProductDoesNotFire() {
    let m = machine()
    let d = Detection(holding: true, itemID: nil, productGuess: "shampoo", confidence: 0.95)
    guard case .notOnWatchlist(let guess) = m.observe(d, at: t0) else {
      return XCTFail("expected an off-list result")
    }
    XCTAssertEqual(guess, "shampoo")
  }

  // MARK: - Cooldowns

  func testTheSameItemCannotRetriggerDuringItsCooldown() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    guard case .fired = m.observe(hit("cereal"), at: t0.addingTimeInterval(1)) else {
      return XCTFail("expected the first trigger")
    }
    m.endInterview(at: t0.addingTimeInterval(30))

    // Well past the global cooldown, well inside the per-item one: the box is
    // in the cart now and keeps appearing in frame.
    let later = t0.addingTimeInterval(200)
    _ = m.observe(hit("cereal"), at: later)
    guard case .itemCoolingDown(let id, _) = m.observe(hit("cereal"), at: later + 1) else {
      return XCTFail("expected the item to be cooling down")
    }
    XCTAssertEqual(id, "cereal")
  }

  func testAnInterviewInFlightBlocksEverything() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    guard case .fired = m.observe(hit("cereal"), at: t0.addingTimeInterval(1)) else {
      return XCTFail("expected the first trigger")
    }
    // A different product picked up mid-interview must wait its turn.
    _ = m.observe(hit("coffee"), at: t0.addingTimeInterval(2))
    guard case .globallyLocked = m.observe(hit("coffee"), at: t0.addingTimeInterval(3)) else {
      return XCTFail("expected the machine to be locked during the interview")
    }
  }

  func testGlobalCooldownRunsFromTheEndOfTheInterview() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    _ = m.observe(hit("cereal"), at: t0.addingTimeInterval(1))
    // A 45s interview: the cooldown starts now, not at t0, or a long interview
    // would eat most of the quiet period that follows it.
    let ended = t0.addingTimeInterval(45)
    m.endInterview(at: ended)

    _ = m.observe(hit("coffee"), at: ended.addingTimeInterval(10))
    guard case .globallyLocked = m.observe(hit("coffee"), at: ended.addingTimeInterval(11)) else {
      return XCTFail("expected to still be inside the global cooldown")
    }

    let free = ended.addingTimeInterval(TriggerPolicy.default.globalCooldown + 1)
    _ = m.observe(hit("coffee"), at: free)
    guard case .fired = m.observe(hit("coffee"), at: free.addingTimeInterval(1)) else {
      return XCTFail("expected a trigger once the global cooldown expired")
    }
  }

  func testAnAbandonedInterviewReleasesTheLock() {
    let m = machine()
    _ = m.observe(hit("cereal"), at: t0)
    guard case .fired = m.observe(hit("cereal"), at: t0.addingTimeInterval(1)) else {
      return XCTFail("expected the first trigger")
    }
    // Stage 2 never calls endInterview -- a crash, or a dropped voice session.
    // The watcher must recover rather than go silent for the rest of the trip.
    let after = t0.addingTimeInterval(TriggerPolicy.default.maxInterviewDuration + 5)
    _ = m.observe(hit("coffee"), at: after)
    guard case .fired = m.observe(hit("coffee"), at: after.addingTimeInterval(1)) else {
      return XCTFail("expected the safety valve to release the lock")
    }
  }
}

/// The models will not always return clean JSON, and a parser that throws on a
/// fenced response would look like a detector outage.
final class CorvusParsingTests: XCTestCase {

  private let items = [
    WatchItem(id: "cereal", displayName: "breakfast cereal", question: "Why that one?")
  ]

  func testParsesBareJSON() throws {
    let d = try DetectionParser.parse(
      #"{"holding": true, "item_id": "cereal", "product": "Cheerios", "confidence": 0.82}"#,
      watchlist: items)
    XCTAssertTrue(d.holding)
    XCTAssertEqual(d.itemID, "cereal")
    XCTAssertEqual(d.productGuess, "Cheerios")
    XCTAssertEqual(d.confidence, 0.82, accuracy: 0.001)
  }

  func testParsesJSONWrappedInFencesAndProse() throws {
    let text = """
    Here is my analysis:
    ```json
    {"holding": true, "item_id": "cereal", "product": null, "confidence": 0.7}
    ```
    """
    let d = try DetectionParser.parse(text, watchlist: items)
    XCTAssertEqual(d.itemID, "cereal")
    XCTAssertNil(d.productGuess)
  }

  func testUnknownItemIDResolvesToNil() throws {
    // An id that is not on the list must never reach the trigger machine.
    let d = try DetectionParser.parse(
      #"{"holding": true, "item_id": "breakfast_cereal_box", "confidence": 0.9}"#,
      watchlist: items)
    XCTAssertTrue(d.holding)
    XCTAssertNil(d.itemID)
  }

  func testDisplayNameIsAcceptedAsAnID() throws {
    let d = try DetectionParser.parse(
      #"{"holding": true, "item_id": "breakfast cereal", "confidence": 0.9}"#,
      watchlist: items)
    XCTAssertEqual(d.itemID, "cereal")
  }

  func testStringNullIsNotAnItem() throws {
    let d = try DetectionParser.parse(
      #"{"holding": true, "item_id": "null", "confidence": 0.5}"#, watchlist: items)
    XCTAssertNil(d.itemID)
  }

  func testConfidenceIsClamped() throws {
    let d = try DetectionParser.parse(
      #"{"holding": true, "item_id": "cereal", "confidence": 4}"#, watchlist: items)
    XCTAssertEqual(d.confidence, 1.0, accuracy: 0.001)
  }

  func testBracesInsideStringsDoNotConfuseTheScanner() throws {
    let d = try DetectionParser.parse(
      #"{"holding": true, "item_id": "cereal", "product": "a }{ weird name", "confidence": 0.6}"#,
      watchlist: items)
    XCTAssertEqual(d.productGuess, "a }{ weird name")
  }

  func testNonJSONThrows() {
    XCTAssertThrowsError(try DetectionParser.parse("I cannot help with that.", watchlist: items))
  }
}
