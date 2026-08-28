import AVFoundation
import Foundation

/// Records an answer and decides on its own when the person has stopped talking.
///
/// A fixed duration would be worse in both directions: it truncates the
/// thoughtful answers that are the entire point of intercepting someone, and it
/// leaves the glasses listening to shelf noise after a two-word one. So this
/// watches the level meter and stops after a stretch of quiet -- with a floor,
/// because everyone pauses before answering, and a ceiling, because a forgotten
/// session must not record the rest of the trip.
@MainActor
final class AnswerRecorder {
  struct Result {
    let url: URL
    let seconds: Double
    let peakDB: Double
    /// Loudest instantaneous reading, which is what the relative silence
    /// threshold is measured down from.
    let loudestDB: Double
    let averageDB: Double
    /// One reading per 100 ms, as the recorder reported it.
    let meterTrace: [Double]
    /// "silence", "ceiling", or "cancelled".
    let endedBecause: String
  }

  enum RecorderError: LocalizedError {
    case permissionDenied
    case failedToStart(String)

    var errorDescription: String? {
      switch self {
      case .permissionDenied: return "Microphone permission denied"
      case .failedToStart(let why): return "Could not start recording: \(why)"
      }
    }
  }

  private var recorder: AVAudioRecorder?
  private var cancelled = false

  func cancel() {
    cancelled = true
    recorder?.stop()
  }

  func record(to url: URL, wav: Bool = false) async throws -> Result {
    guard await Self.requestPermission() else { throw RecorderError.permissionDenied }

    // 16 kHz mono: HFP delivers no more than this anyway, speech models want no
    // more than this, and it keeps a whole session's audio small enough to pull
    // off the phone over a cable.
    //
    // WAV rather than AAC when a model has to read it: Gemini's inline audio
    // accepts wav/mp3/aiff/aac/ogg/flac, and an .m4a is AAC inside an MP4
    // container, which is the one shape on that list it can refuse. The size
    // difference is irrelevant for a thirty-second answer.
    let settings: [String: Any] = wav
      ? [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
      : [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
      ]

    let recorder: AVAudioRecorder
    do {
      recorder = try AVAudioRecorder(url: url, settings: settings)
    } catch {
      throw RecorderError.failedToStart(error.localizedDescription)
    }
    recorder.isMeteringEnabled = true
    guard recorder.record() else {
      throw RecorderError.failedToStart("recorder refused to start")
    }
    self.recorder = recorder
    cancelled = false

    let started = Date()
    let ceiling = CorvusConfig.maxAnswerSeconds
    let silenceNeeded = CorvusConfig.silenceSeconds
    let threshold = CorvusConfig.silenceThresholdDB
    let onsetThreshold = CorvusConfig.speechOnsetDB
    let waitForSpeech = CorvusConfig.maxWaitForSpeechSeconds
    // Speech has to clear the bar twice running before it counts, so a single
    // knock or cough does not start the answer.
    var aboveRun = 0
    var speaking = false

    var peak = -160.0
    var sum = 0.0
    var samples = 0
    var quietSince: Date?
    var reason = "ceiling"
    // Loudest instantaneous reading so far, which is what makes the threshold
    // relative. A fixed cutoff cannot serve both a quiet mumble and a shout in
    // an aisle: field audio had one real answer whose entire waveform sat below
    // the fixed -35 dB line, so the recorder counted a person talking as silence
    // and only captured them because the minimum duration happened to cover it.
    var loudest = -160.0
    // Every meter reading, at 10 Hz. Recorded because tuning this threshold
    // from anything else has now failed twice: a fixed cutoff counted a person
    // talking as silence, and re-deriving the levels offline from the WAV gave
    // numbers that disagree with what the recorder itself reports. The only
    // trustworthy input is what AVAudioRecorder actually saw, so it gets kept.
    var trace: [Double] = []

    let tick: UInt64 = 100_000_000  // 0.1s
    while true {
      try? await Task.sleep(nanoseconds: tick)
      if cancelled { reason = "cancelled"; break }

      recorder.updateMeters()
      let level = Double(recorder.averagePower(forChannel: 0))
      peak = max(peak, Double(recorder.peakPower(forChannel: 0)))
      sum += level
      samples += 1
      loudest = max(loudest, level)
      trace.append((level * 10).rounded() / 10)

      // Anything this far below the loudest thing heard is the gap between
      // words rather than speech. Only trusted once something has been heard at
      // all -- before that, an absolute floor is all there is to go on, and it
      // is deliberately generous.
      let effectiveThreshold = loudest > threshold
        ? max(threshold, loudest - CorvusConfig.silenceDropDB)
        : threshold

      let elapsed = Date().timeIntervalSince(started)
      if elapsed >= ceiling { reason = "ceiling"; break }

      // Two phases, because a single one cannot serve both ends. Before anyone
      // has spoken, quiet means "still thinking" and must never end the
      // recording -- field audio caught a wearer pausing 3.9s before answering,
      // against a cutoff that fired at 4.0s. Only once speech has actually been
      // heard does quiet start to mean "finished".
      guard speaking else {
        aboveRun = level > onsetThreshold ? aboveRun + 1 : 0
        if aboveRun >= 2 {
          speaking = true
          quietSince = nil
        } else if elapsed >= waitForSpeech {
          reason = "no speech"
          break
        }
        continue
      }

      if level < effectiveThreshold {
        let since = quietSince ?? Date()
        quietSince = since
        if Date().timeIntervalSince(since) >= silenceNeeded { reason = "silence"; break }
      } else {
        quietSince = nil
      }
    }

    recorder.stop()
    self.recorder = nil

    return Result(
      url: url,
      seconds: Date().timeIntervalSince(started),
      peakDB: peak,
      loudestDB: loudest,
      averageDB: samples > 0 ? sum / Double(samples) : -160,
      meterTrace: trace,
      endedBecause: reason)
  }

  private static func requestPermission() async -> Bool {
    if AVAudioApplication.shared.recordPermission == .granted { return true }
    return await withCheckedContinuation { cont in
      AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
    }
  }
}
