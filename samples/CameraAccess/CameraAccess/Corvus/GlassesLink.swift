import Combine
import Foundation
import MWDATCamera
import MWDATCore

/// Corvus's eyes on the glasses link, one layer below the LiveKit seam.
///
/// The DAT view model (upstream VisionClaw code) keeps the session machinery.
/// This object takes a few one-line reports from it and turns them into two
/// things the rest of Corvus reads: wait-state wording that names which layer
/// is being waited on, and a retry delay that backs off once the glasses are
/// refusing sessions. It also owns the diagnostics for the layers below the
/// session -- per-device link state, compatibility and thermal level -- which
/// the SDK exposes and the sample app never looked at.
///
/// Layers, bottom up: Bluetooth between glasses and phone; the accessory
/// session the SDK reports as `LinkState`; registration and permission through
/// the Meta AI app; then the device session this app asks for. Corvus can only
/// observe the first three. The fourth is where the retry policy lives.
@MainActor
final class GlassesLinkMonitor: ObservableObject {
  static let shared = GlassesLinkMonitor()

  /// A session that reaches `.stopped` this soon after `.starting`, without
  /// ever being `.started`, was refused by the glasses rather than dropped.
  /// Observed refusals took about 60 ms; a genuine drop after start takes
  /// seconds. Refusals happen when another session already holds the glasses,
  /// including one left behind by a copy of this app that died mid-stream.
  static let refusalWindow: TimeInterval = 0.5
  /// Consecutive refusals before the glasses are treated as held rather than
  /// unlucky. Below this the normal cadence gives a transient stop a fast retry.
  static let refusalThreshold = 3
  static let normalRetry: TimeInterval = 1.5
  /// Each attempt against held glasses makes them chime and none succeeds
  /// until they are power-cycled, so once refusal is established the loop
  /// only needs to notice when that has happened.
  static let refusedRetry: TimeInterval = 10

  @Published private(set) var activeDevice: DeviceIdentifier?
  @Published private(set) var activeDeviceName: String?
  @Published private(set) var linkState: LinkState?
  @Published private(set) var sessionState: DeviceSessionState?
  @Published private(set) var streamState: StreamState?
  @Published private(set) var refusals = 0

  private var wearables: (any WearablesInterface)?
  private var devicesTask: Task<Void, Never>?
  private var linkTokens: [DeviceIdentifier: any AnyListenerToken] = [:]
  private var thermalTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
  private var knownDevices: Set<DeviceIdentifier> = []
  private var linkSince: [DeviceIdentifier: CFAbsoluteTime] = [:]
  private var lastLink: [DeviceIdentifier: LinkState] = [:]
  private var compatTokens: [DeviceIdentifier: any AnyListenerToken] = [:]
  private var activeSince: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
  private var sessionStartingAt: CFAbsoluteTime?
  private var sessionStartedAt: CFAbsoluteTime?
  private var createFailures = 0
  private var lastCreateFailure: String?

  var isRefusing: Bool { refusals >= Self.refusalThreshold }
  var retryDelay: TimeInterval { isRefusing ? Self.refusedRetry : Self.normalRetry }

  // MARK: - Layers below the session (observe only)

  /// Follows every device the SDK knows about, for the life of the app.
  func attach(wearables: any WearablesInterface) {
    guard devicesTask == nil else { return }
    self.wearables = wearables
    devicesTask = Task { @MainActor [weak self] in
      for await ids in wearables.devicesStream() {
        self?.devicesChanged(ids)
      }
    }
  }

  private func devicesChanged(_ ids: [DeviceIdentifier]) {
    let now = Set(ids)
    for id in now.subtracting(knownDevices) { watch(id) }
    for id in knownDevices.subtracting(now) {
      NSLog("[Link] device gone from the SDK list: %@", short(id))
      if let token = linkTokens.removeValue(forKey: id) { Task { await token.cancel() } }
      if let token = compatTokens.removeValue(forKey: id) { Task { await token.cancel() } }
      thermalTasks.removeValue(forKey: id)?.cancel()
    }
    knownDevices = now
    if ids.isEmpty { NSLog("[Link] the SDK lists no glasses (not registered, or Meta AI has none paired)") }
  }

  private func watch(_ id: DeviceIdentifier) {
    guard let wearables, let device = wearables.deviceForIdentifier(id) else {
      NSLog("[Link] device %@ listed but not resolvable", short(id))
      return
    }
    let name = device.nameOrId()
    linkSince[id] = CFAbsoluteTimeGetCurrent()
    lastLink[id] = device.linkState
    NSLog("[Link] device %@ (%@) type=%@ compat=%@ link=%@",
          name, short(id), String(describing: device.deviceType()),
          device.compatibility().displayString, String(describing: device.linkState))
    if activeDevice == nil { linkState = device.linkState }
    linkTokens[id] = device.addLinkStateListener { [weak self] state in
      Task { @MainActor [weak self] in self?.linkChanged(id, name: name, to: state) }
    }
    // Compatibility reads "Undefined" until the glasses have answered; the
    // settled value is the one that says whether a firmware or SDK update is due.
    compatTokens[id] = device.addCompatibilityListener { compat in
      Task { @MainActor in NSLog("[Link] %@ compatibility %@", name, compat.displayString) }
    }
    // Thermal level is the one piece of device state the SDK streams. Session
    // errors name thermal limits as a stop reason, so the ramp is worth a line.
    thermalTasks[id] = Task { @MainActor [weak self] in
      var last: ThermalLevel?
      for await state in wearables.deviceStateStream(for: id) {
        guard self != nil, state.thermalLevel != last else { continue }
        last = state.thermalLevel
        NSLog("[Link] %@ thermal %@", name, String(describing: state.thermalLevel))
      }
    }
  }

  private func linkChanged(_ id: DeviceIdentifier, name: String, to state: LinkState) {
    // The SDK repeats a state; only a change is a reading.
    guard lastLink[id] != state else { return }
    lastLink[id] = state
    let now = CFAbsoluteTimeGetCurrent()
    let held = now - (linkSince[id] ?? now)
    linkSince[id] = now
    NSLog("[Link] %@ link %@ (previous state held %.1fs)", name, String(describing: state), held)
    if id == activeDevice || activeDevice == nil { linkState = state }
  }

  // MARK: - Reports from the stream view model

  func noteActiveDevice(_ id: DeviceIdentifier?) {
    let now = CFAbsoluteTimeGetCurrent()
    let device = id.flatMap { wearables?.deviceForIdentifier($0) }
    let name = device?.nameOrId() ?? id.map(short)
    NSLog("[Link] active device: %@ (previous state held %.1fs%@)",
          name ?? "none", now - activeSince,
          createFailures > 0 ? ", \(createFailures) session attempts failed meanwhile" : "")
    activeSince = now
    activeDevice = id
    activeDeviceName = name
    linkState = device?.linkState ?? linkState
    createFailures = 0
    lastCreateFailure = nil
    if id == nil {
      refusals = 0
      sessionState = nil
      streamState = nil
    }
  }

  func noteSessionState(_ state: DeviceSessionState) {
    let now = CFAbsoluteTimeGetCurrent()
    sessionState = state
    switch state {
    case .starting:
      sessionStartingAt = now
      sessionStartedAt = nil
      NSLog("[Link] session starting")
    case .started:
      sessionStartedAt = now
      let took = now - (sessionStartingAt ?? now)
      if refusals > 0 {
        NSLog("[Link] session started in %.2fs, ending a run of %d refusals", took, refusals)
      } else {
        NSLog("[Link] session started in %.2fs", took)
      }
      refusals = 0
    case .paused:
      NSLog("[Link] session paused (glasses gesture or system; waiting, not restarting)")
    case .stopping:
      break
    case .stopped, .idle:
      if let startedAt = sessionStartedAt {
        NSLog("[Link] session %@ after running %.0fs", String(describing: state), now - startedAt)
      } else if let startingAt = sessionStartingAt, now - startingAt < Self.refusalWindow {
        refusals += 1
        NSLog("[Link] session refused: %@ %.0f ms after starting, never started (%d in a row%@)",
              String(describing: state), (now - startingAt) * 1000, refusals,
              isRefusing ? "; treating the glasses as held, retrying every \(Int(Self.refusedRetry))s" : "")
      } else {
        NSLog("[Link] session %@ before it started", String(describing: state))
      }
      sessionStartingAt = nil
      sessionStartedAt = nil
    }
  }

  func noteStreamState(_ state: StreamState) {
    streamState = state
  }

  func noteSessionError(_ error: DeviceSessionError) {
    NSLog("[Link] session error: %@", String(describing: error))
  }

  func noteSessionCreateFailed(_ error: DeviceSessionError) {
    createFailures += 1
    let text = String(describing: error)
    // The retry loop runs every 1.5 s; log the first, any change, then every 20th.
    if createFailures == 1 || text != lastCreateFailure || createFailures % 20 == 0 {
      NSLog("[Link] session create/start failed: %@ (attempt %d, active device %@)",
            text, createFailures, activeDeviceName ?? "none")
    }
    lastCreateFailure = text
  }

  /// The permission check waits on the glasses. At launch with folded glasses
  /// it has sat for minutes with nothing else in the log, so the duration is
  /// the reading.
  func notePermissionCheck(_ result: String, took: TimeInterval) {
    NSLog("[Link] camera permission %@ (checked in %.1fs)", result, took)
  }

  // MARK: - What the UI shows

  /// Wait-state wording for the layers this object can see. Nil when the wait
  /// is something else (permission, hinges, a stream error), which the stream
  /// view model names itself.
  var placeholder: (title: String, caption: String)? {
    if isRefusing {
      return ("Glasses are busy",
              "Another session is holding the glasses. Power them off and on, then come back. Folding is not enough.")
    }
    guard activeDevice != nil else {
      switch linkState {
      case .connecting:
        return ("Glasses connecting", "Your phone sees the glasses and is linking to them.")
      default:
        return ("Glasses not connected to your phone",
                "This is the Bluetooth link between the glasses and the phone, not the app. Open the hinges and bring them close. They chime when the link is up, then the camera starts on its own.")
      }
    }
    if sessionState == .paused {
      return ("Glasses paused", "Tap the glasses to resume, or wait for the session to come back.")
    }
    if sessionState == .started, streamState == .streaming {
      // Every layer reports up and frames still stopped. The one state with
      // no name from the SDK, so say exactly that much.
      return ("No video from the glasses",
              "They are connected and the camera session is up, but frames stopped arriving. Waiting for them to resume.")
    }
    return ("Glasses connected", "Starting the camera.")
  }

  /// One line for Settings.
  var summary: String {
    if isRefusing { return "Session refused ×\(refusals) · power-cycle the glasses" }
    guard let name = activeDeviceName else {
      switch linkState {
      case .connecting: return "Glasses connecting"
      case .disconnected: return "Glasses paired, not connected"
      default: return knownDevices.isEmpty ? "No glasses known to the SDK" : "No glasses connected"
      }
    }
    let session: String
    switch sessionState {
    case .started: session = "session started"
    case .starting: session = "session starting"
    case .paused: session = "session paused"
    case .stopping, .stopped, .idle, nil: session = refusals > 0 ? "session refused ×\(refusals)" : "no session"
    }
    return "\(name) · \(session)"
  }

  private func short(_ id: DeviceIdentifier) -> String { String(id.prefix(8)) }
}
