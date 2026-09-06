import XCTest
@testable import CameraAccess

@MainActor
final class CorvusMissionCoordinatorTests: XCTestCase {
  func testEndWhileConnectionIsSuspendedDisposesLateCapture() async {
    var completeConnect: CheckedContinuation<Void, Never>?
    var enteredConnect: CheckedContinuation<Void, Never>?
    var captureStopped: CheckedContinuation<Void, Never>?
    var running = false
    var connected = false
    var gatewayEnds = 0
    let coordinator = MissionCoordinator(media: .init(
      connect: {
        enteredConnect?.resume(); enteredConnect = nil
        await withCheckedContinuation { completeConnect = $0 }
        running = true; connected = true
      },
      stopCapture: { running = false; captureStopped?.resume(); captureStopped = nil },
      disconnect: { running = false; connected = false },
      endOnGateway: { gatewayEnds += 1 }))
    let session = LiveKitSession()
    let study = StudyStore.shared.active
    let watcher = WatcherCoordinator(study: study)
    coordinator.attach(session: session, watcher: watcher, stopDAT: {})
    await withCheckedContinuation { continuation in
      enteredConnect = continuation
      coordinator.start(study: study, source: .iPhoneCamera, engine: .gemini, startDAT: {})
    }
    let ending = Task { await coordinator.end() }
    await withCheckedContinuation { captureStopped = $0 }
    XCTAssertFalse(running)
    XCTAssertFalse(watcher.isRunning)
    completeConnect?.resume()
    await ending.value
    XCTAssertFalse(running)
    XCTAssertFalse(connected)
    XCTAssertEqual(gatewayEnds, 1)
    XCTAssertEqual(coordinator.lifecycle.phase, .ended)
  }
}
