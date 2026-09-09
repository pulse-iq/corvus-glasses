import XCTest
@testable import CameraAccess

final class CorvusMissionStateTests: XCTestCase {
  func testLateReadyCannotRestartEndedMission() {
    var state = MissionState()
    let generation = state.begin()
    state.end()
    state.apply(phase: .shopping, generation: generation)
    XCTAssertEqual(state.phase, .ending)
  }
  func testDuplicateStartAndRecoveryKeepStartedLatch() {
    var state = MissionState()
    let generation = state.begin()
    XCTAssertEqual(generation, state.begin())
    XCTAssertFalse(state.started)
    state.apply(phase: .shopping, generation: generation)
    state.apply(phase: .reconnecting, generation: generation)
    XCTAssertEqual(state.phase, .reconnecting)
    XCTAssertTrue(state.started)
  }
  func testNewMissionForgetsPreviousStart() {
    var state = MissionState()
    let first = state.begin()
    state.apply(phase: .shopping, generation: first)
    state.end(); state.finishedEnding()
    _ = state.begin()
    XCTAssertFalse(state.started)
  }
}
