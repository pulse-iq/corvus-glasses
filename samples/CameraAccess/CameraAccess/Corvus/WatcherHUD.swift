import SwiftUI

/// The watcher, made visible on the live camera screen.
///
/// The bench screen drives the phone camera; this is the same readout over the
/// glasses feed, where it matters most. Without it the watcher is invisible on the
/// glasses -- detections land in a log file on the device, and the only way to
/// know whether a pickup registered is to pull the logs afterwards, by which
/// point the trip is over.
///
/// Deliberately shows *why* nothing fired, not just when something did: during
/// tuning, "confidence 0.41 on cereal" and "saw no hands" call for opposite
/// fixes, and a silent screen cannot tell them apart.
struct WatcherHUD: View {
  @ObservedObject var watcher: WatcherCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if watcher.isIntercepting {
        interceptingBanner
      } else if let trigger = watcher.triggers.first {
        triggerBanner(trigger)
      }
      status
    }
    .padding(10)
    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    .foregroundStyle(.white)
    .font(.system(size: 12, weight: .regular, design: .monospaced))
  }

  /// An intercept has the floor. Distinct from the trigger banner because during a
  /// field test the two failure modes look identical from outside the glasses:
  /// a trigger that never started an intercept, and an intercept that started
  /// but is silent.
  private var interceptingBanner: some View {
    HStack(spacing: 6) {
      Image(systemName: "waveform")
      Text("INTERCEPTING")
        .font(.system(size: 13, weight: .bold, design: .monospaced))
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.blue.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  /// The moment an intercept would speak. Shows the question that would be asked,
  /// because "did it fire at the right instant" and "would it have asked the
  /// right thing" are the two questions a field test has to answer.
  private func triggerBanner(_ trigger: Trigger) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("TRIGGER  \(trigger.item.displayName)")
        .font(.system(size: 13, weight: .bold, design: .monospaced))
      Text("\"\(trigger.item.question)\"")
        .font(.system(size: 12))
        .italic()
      Text(String(format: "conf %.2f · %d hits · %@",
                  trigger.confidence, trigger.hitCount, relative(trigger.firedAt)))
        .foregroundStyle(.white.opacity(0.7))
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.green.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Circle()
          .fill(watcher.isRunning ? (watcher.isDetecting ? .yellow : .green) : .gray)
          .frame(width: 7, height: 7)
        Text(watcher.study.id)
        Text("·").foregroundStyle(.white.opacity(0.4))
        Text("\(watcher.framesSampled)/\(watcher.framesSeen)")
          .foregroundStyle(.white.opacity(0.7))
        if let ms = watcher.lastLatency {
          Text(String(format: "· %.0fms", ms * 1000))
            .foregroundStyle(.white.opacity(0.7))
        }
      }
      if let d = watcher.lastDetection {
        Text(verbatim: line(for: d))
          .foregroundStyle(.white.opacity(0.85))
      }
      if let decision = watcher.lastDecision {
        Text(decision.label)
          .foregroundStyle(.cyan.opacity(0.9))
      }
      if let error = watcher.lastError {
        Text(error)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
  }

  private func line(for d: Detection) -> String {
    guard d.holding else { return "not holding" }
    let what = d.itemID ?? d.productGuess ?? "something"
    return String(format: "holding %@ (%.2f)", what, d.confidence)
  }

  private func relative(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
  }
}
