import Foundation

enum MissionPhase: String, Codable {
  case idle, starting, welcome, shopping, interviewing, reconnecting, ending, ended
}

/// Pure lifecycle fence. Monotonic deadlines can shorten, but never extend.
struct MissionState {
  private(set) var phase: MissionPhase = .idle
  private(set) var generation = 0
  private(set) var deadlineUptime: TimeInterval?
  mutating func begin() -> Int {
    guard phase == .idle || phase == .ended else { return generation }
    generation += 1
    phase = .starting
    deadlineUptime = nil
    return generation
  }
  mutating func apply(phase: MissionPhase, generation: Int, deadline: Double?, serverNow: Double, uptime: Double) {
    guard generation == self.generation, self.phase != .ending, self.phase != .ended, self.phase != .idle else { return }
    if let deadline {
      let proposed = uptime + max(0, (deadline - serverNow) / 1000)
      deadlineUptime = min(deadlineUptime ?? proposed, proposed)
    }
    self.phase = phase
  }
  mutating func end() { generation += 1; phase = .ending }
  mutating func finishedEnding() { phase = .ended }
  func expired(uptime: Double) -> Bool { deadlineUptime.map { uptime >= $0 } ?? false }
}
