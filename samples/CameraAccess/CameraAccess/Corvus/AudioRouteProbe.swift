import AVFoundation
import Combine
import SwiftUI

/// Proof that DAT video is still arriving, so the audio probe can tell a
/// working route from a route that cost us the camera.
///
/// Lives here rather than in the watcher because it exists for the probe: the
/// watcher's own frame counter only ticks while the watcher is running, and
/// the probe needs a signal that survives being on another screen.
@MainActor
final class FrameHeartbeat: ObservableObject {
  static let shared = FrameHeartbeat()
  @Published private(set) var total = 0
  @Published private(set) var lastAt: Date?

  func tick() {
    total += 1
    lastAt = Date()
  }

  /// Frames are ~24fps when healthy, so a second of silence is already a stall.
  var isLive: Bool {
    guard let lastAt else { return false }
    return Date().timeIntervalSince(lastAt) < 1.5
  }
}

/// Answers one question before Stage 2 gets designed: can this app speak
/// through the glasses, and hear through them, while DAT streams video?
///
/// The DAT SDK has no audio API whatsoever -- its entire permission set is
/// `case camera`. So if the glasses speak, it is because iOS routes to them as
/// an ordinary Bluetooth headset, completely outside Meta's SDK. That is
/// plausible but unverified, and the specific risk is that the glasses refuse
/// the audio channel while their camera is streaming. Getting this wrong means
/// rewriting Stage 2, so it gets measured rather than assumed.
///
/// The interesting reading is not what you hear -- it is `currentRoute`, which
/// names the hardware iOS actually chose.
@MainActor
final class AudioProbe: ObservableObject {
  @Published private(set) var outputs: [String] = []
  @Published private(set) var inputs: [String] = []
  @Published private(set) var availableInputs: [String] = []
  @Published private(set) var mode = "not configured"
  @Published private(set) var status = ""
  @Published private(set) var isRecording = false

  private var recorder: AVAudioRecorder?
  private var player: AVAudioPlayer?
  private let speaker = AVSpeechSynthesizer()
  private var routeObserver: NSObjectProtocol?

  private var recordingURL: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("corvus-probe.m4a")
  }

  init() {
    refreshRoute()
    // Route changes are the whole point: if engaging the mic drops the glasses
    // from the route, that shows up here rather than as a confusing silence.
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil, queue: .main
    ) { [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
        .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
      MainActor.assumeIsolated {
        self?.refreshRoute()
        self?.status = "route changed (\(Self.describe(reason)))"
      }
    }
  }

  deinit {
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
  }

  // MARK: - Reading the route

  func refreshRoute() {
    let session = AVAudioSession.sharedInstance()
    outputs = session.currentRoute.outputs.map { "\($0.portName)  [\($0.portType.rawValue)]" }
    inputs = session.currentRoute.inputs.map { "\($0.portName)  [\($0.portType.rawValue)]" }
    availableInputs = (session.availableInputs ?? []).map {
      "\($0.portName)  [\($0.portType.rawValue)]"
    }
  }

  /// True when anything in the route looks like a Bluetooth peripheral, which
  /// is the only way glasses audio can appear.
  var routedToBluetooth: Bool {
    let bt: Set<String> = [
      AVAudioSession.Port.bluetoothA2DP.rawValue,
      AVAudioSession.Port.bluetoothHFP.rawValue,
      AVAudioSession.Port.bluetoothLE.rawValue,
    ]
    return (outputs + inputs).contains { line in bt.contains { line.contains($0) } }
  }

  // MARK: - Configuring

  /// Playback-only, high quality. A2DP is stereo and full bandwidth but offers
  /// no microphone -- this is the ceiling for a speak-only interviewer.
  func configureForPlaybackOnly() {
    apply(category: .playback, options: [.allowBluetoothA2DP], label: "playback + A2DP")
  }

  /// Two-way. HFP carries a microphone but drags the whole route down to
  /// narrowband -- expect the voice to sound like a phone call. This is what a
  /// conversational Stage 2 would actually run on.
  func configureForTwoWay() {
    apply(
      category: .playAndRecord,
      options: [GlassesAudioSession.hfpOption, .allowBluetoothA2DP, .duckOthers],
      label: "playAndRecord + HFP")

    // Bluetooth input is not chosen automatically; ask for it explicitly.
    let session = AVAudioSession.sharedInstance()
    let bluetooth = (session.availableInputs ?? []).first {
      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
    }
    if let bluetooth {
      do {
        try session.setPreferredInput(bluetooth)
        status += "  · preferred input: \(bluetooth.portName)"
      } catch {
        status += "  · could not prefer \(bluetooth.portName): \(error.localizedDescription)"
      }
    } else {
      status += "  · no Bluetooth input offered"
    }
    refreshRoute()
  }

  func deactivate() {
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      mode = "not configured"
      status = "session deactivated"
    } catch {
      status = "deactivate failed: \(error.localizedDescription)"
    }
    refreshRoute()
  }

  private func apply(
    category: AVAudioSession.Category,
    options: AVAudioSession.CategoryOptions,
    label: String
  ) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(category, mode: .voiceChat, options: options)
      try session.setActive(true)
      mode = label
      status = "session active"
    } catch {
      mode = label
      status = "FAILED: \(error.localizedDescription)"
    }
    refreshRoute()
  }

  // MARK: - Making noise

  func speak() {
    let utterance = AVSpeechUtterance(
      string: "Corvus audio test. If you can hear this in your glasses, output is working.")
    utterance.rate = 0.5
    speaker.speak(utterance)
    status = "speaking"
    refreshRoute()
  }

  func recordThenPlayBack(seconds: TimeInterval = 4) {
    AVAudioApplication.requestRecordPermission { [weak self] granted in
      Task { @MainActor in
        guard let self else { return }
        guard granted else {
          self.status = "microphone permission denied"
          return
        }
        self.startRecording(seconds: seconds)
      }
    }
  }

  private func startRecording(seconds: TimeInterval) {
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
    ]
    do {
      let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
      recorder.record()
      self.recorder = recorder
      isRecording = true
      status = "recording \(Int(seconds))s — say something"
      refreshRoute()

      Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        self.finishRecording()
      }
    } catch {
      status = "record failed: \(error.localizedDescription)"
    }
  }

  private func finishRecording() {
    recorder?.stop()
    recorder = nil
    isRecording = false
    do {
      let player = try AVAudioPlayer(contentsOf: recordingURL)
      player.play()
      self.player = player
      status = "playing back — whose microphone did that sound like?"
    } catch {
      status = "playback failed: \(error.localizedDescription)"
    }
    refreshRoute()
  }

  private static func describe(_ reason: AVAudioSession.RouteChangeReason?) -> String {
    switch reason {
    case .newDeviceAvailable: return "device connected"
    case .oldDeviceUnavailable: return "device disconnected"
    case .categoryChange: return "category change"
    case .override: return "override"
    case .routeConfigurationChange: return "reconfigured"
    case .wakeFromSleep: return "wake"
    case .noSuitableRouteForCategory: return "no suitable route"
    default: return "other"
    }
  }
}

struct AudioRouteProbeView: View {
  @StateObject private var probe = AudioProbe()
  @ObservedObject private var heartbeat = FrameHeartbeat.shared
  @State private var ticker = Date()

  private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  var body: some View {
    Form {
      Section(header: Text("DAT video"), footer: Text(
        "This has to stay live while you test audio. If frames stop the moment "
        + "a session goes active, the glasses will not do camera and audio at "
        + "once — and that is the finding.")) {
        HStack {
          Circle()
            .fill(heartbeat.isLive ? .green : .red)
            .frame(width: 10, height: 10)
          Text(heartbeat.isLive ? "Streaming" : "No frames")
          Spacer()
          Text("\(heartbeat.total) frames")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }

      Section(header: Text("Current route")) {
        LabeledContent("Mode", value: probe.mode)
        routeList("Output", probe.outputs)
        routeList("Input", probe.inputs)
        HStack {
          Text("Bluetooth in route")
          Spacer()
          Text(probe.routedToBluetooth ? "yes" : "no")
            .foregroundStyle(probe.routedToBluetooth ? .green : .secondary)
        }
      }

      Section(header: Text("Available inputs")) {
        routeList("", probe.availableInputs)
      }

      Section(header: Text("1 · Output only"), footer: Text(
        "A2DP: full bandwidth, no microphone. The ceiling for an interviewer "
        + "that only speaks.")) {
        Button("Configure playback + A2DP") { probe.configureForPlaybackOnly() }
        Button("Speak a test phrase") { probe.speak() }
      }

      Section(header: Text("2 · Two-way"), footer: Text(
        "HFP carries a microphone but narrows the whole route — expect "
        + "phone-call quality. This is what a conversational Stage 2 runs on.")) {
        Button("Configure playAndRecord + HFP") { probe.configureForTwoWay() }
        Button("Speak a test phrase") { probe.speak() }
        Button(probe.isRecording ? "Recording…" : "Record 4s, then play it back") {
          probe.recordThenPlayBack()
        }
        .disabled(probe.isRecording)
      }

      Section {
        Button("Refresh route") { probe.refreshRoute() }
        Button("Deactivate session", role: .destructive) { probe.deactivate() }
      } footer: {
        Text(probe.status).font(.footnote)
      }
    }
    .navigationTitle("Audio route probe")
    .navigationBarTitleDisplayMode(.inline)
    .onReceive(clock) { now in
      ticker = now         // redraw so the heartbeat light can go stale
      probe.refreshRoute()
    }
  }

  @ViewBuilder
  private func routeList(_ label: String, _ values: [String]) -> some View {
    if values.isEmpty {
      HStack {
        if !label.isEmpty { Text(label) }
        Spacer()
        Text("none").foregroundStyle(.secondary)
      }
    } else {
      ForEach(values, id: \.self) { value in
        HStack(alignment: .top) {
          if !label.isEmpty {
            Text(label).foregroundStyle(.secondary)
            Spacer()
          }
          Text(value)
            .font(.system(.footnote, design: .monospaced))
            .multilineTextAlignment(.trailing)
        }
      }
    }
  }
}
