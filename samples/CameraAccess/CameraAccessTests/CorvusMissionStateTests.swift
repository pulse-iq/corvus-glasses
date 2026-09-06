import XCTest
@testable import CameraAccess

final class CorvusMissionStateTests: XCTestCase {
  func testLateReadyCannotRestartEndedMission() {
    var state = MissionState()
    let generation = state.begin()
    state.end()
    state.apply(phase: .shopping, generation: generation, deadline: 100, serverNow: 0, uptime: 0)
    XCTAssertEqual(state.phase, .ending)
  }
  func testDuplicateStartAndRecoveryKeepDeadline() {
    var state = MissionState()
    let generation = state.begin()
    XCTAssertEqual(generation, state.begin())
    state.apply(phase: .shopping, generation: generation, deadline: 100_000, serverNow: 0, uptime: 5)
    state.apply(phase: .reconnecting, generation: generation, deadline: nil, serverNow: 20_000, uptime: 25)
    state.apply(phase: .shopping, generation: generation, deadline: 200_000, serverNow: 20_000, uptime: 25)
    XCTAssertEqual(state.deadlineUptime, 105)
    XCTAssertTrue(state.expired(uptime: 105))
  }
}
