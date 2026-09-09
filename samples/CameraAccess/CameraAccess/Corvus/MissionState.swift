import Foundation

enum MissionPhase: String, Codable {
  case idle, starting, welcome, shopping, interviewing, reconnecting, ending, ended
}

/// Pure lifecycle fence. There is no mission time limit; `started` latches once
/// the worker has reported a running mission so setup timeouts and reconnect
/// handling know the difference between "never came up" and "dropped".
struct MissionState {
  private(set) var phase: MissionPhase = .idle
  private(set) var generation = 0
  private(set) var started = false
  mutating func begin() -> Int {
    guard phase == .idle || phase == .ended else { return generation }
    generation += 1
    phase = .starting
    started = false
    return generation
  }
  mutating func apply(phase: MissionPhase, generation: Int) {
    guard generation == self.generation, self.phase != .ending, self.phase != .ended, self.phase != .idle else { return }
    if [.welcome, .shopping, .interviewing].contains(phase) { started = true }
    self.phase = phase
  }
  mutating func end() { generation += 1; phase = .ending }
  mutating func finishedEnding() { phase = .ended }
}
