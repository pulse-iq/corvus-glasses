import AVFoundation
import Foundation
import LiveKit

/// Measures what the microphone capture engine actually hands to WebRTC.
///
/// Why this exists. On 2026-09-11 the second mission of every back-to-back
/// pair captured silence from the glasses' HFP microphone while the first was
/// fine. Every signal we had sat downstream of the phone: the worker's
/// recogniser received audio (so frames were flowing), the server's speaker
/// flag never fired (so the frames carried nothing), and the phone's own log
/// said the mic was on and routed to the glasses. None of that could say
/// whether the phone captured silence or never captured at all, and the fix
/// (keeping the SDK's capture engine prepared across calls, see
/// LiveKitSession.start) was found by elimination rather than by reading it
/// off a log. This tap reads the level at the one point that settles it.
///
/// What it is kept for. The capture engine can still be stopped and restarted
/// by things missions do not control: an iOS audio interruption (a phone call,
/// Siri), the glasses dropping and re-establishing their Bluetooth link, or a
/// long background suspension. If a microphone comes up dead after one of
/// those, this is what tells the two failure shapes apart -- a floor-level
/// reading (the glasses' mic is attached but quiet) from "captured=none" (the
/// engine is not delivering buffers) -- and each wants a different fix. A
/// silent microphone and a silent participant look identical downstream, so
/// any automatic recovery has to be keyed on this reading, not on the absence
/// of speech. It is also the only place that names the capture format
/// (16 kHz mono is the glasses' HFP link; 48 kHz means the route fell back to
/// the phone's own microphone).
///
/// Read and reset by the call screen's two-second `[AudioStats]` line.
final class MicLevelMeter: AudioRenderer, @unchecked Sendable {
  static let shared = MicLevelMeter()

  private let lock = NSLock()
  private var sumSquares: Double = 0
  private var samples: Int = 0
  private var peak: Float = 0
  private var buffers: Int = 0
  private var format: String = ""

  func render(pcmBuffer: AVAudioPCMBuffer) {
    let frames = Int(pcmBuffer.frameLength)
    guard frames > 0 else { return }
    var localSum: Double = 0
    var localPeak: Float = 0
    if let data = pcmBuffer.floatChannelData {
      let channel = data[0]
      for i in 0..<frames {
        let v = channel[i]
        localSum += Double(v * v)
        localPeak = max(localPeak, abs(v))
      }
    } else if let data = pcmBuffer.int16ChannelData {
      let channel = data[0]
      for i in 0..<frames {
        let v = Float(channel[i]) / 32768
        localSum += Double(v * v)
        localPeak = max(localPeak, abs(v))
      }
    } else {
      return
    }
    lock.lock()
    sumSquares += localSum
    samples += frames
    peak = max(peak, localPeak)
    buffers += 1
    if format.isEmpty {
      format = "\(Int(pcmBuffer.format.sampleRate))Hz/\(pcmBuffer.format.channelCount)ch"
    }
    lock.unlock()
  }

  /// One line for the log, then the window starts again.
  func snapshot() -> String {
    lock.lock()
    defer {
      sumSquares = 0; samples = 0; peak = 0; buffers = 0
      lock.unlock()
    }
    guard buffers > 0, samples > 0 else { return "captured=none" }
    let rms = sqrt(sumSquares / Double(samples))
    let rmsDB = rms > 0 ? 20 * log10(rms) : -120
    let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -120
    return String(format: "captured=%.0fdBFS peak=%.0f (%d buffers, %@)", rmsDB, peakDB, buffers, format)
  }
}
