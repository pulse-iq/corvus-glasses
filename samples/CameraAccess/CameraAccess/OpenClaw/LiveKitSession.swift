import AVFoundation
import Foundation
import LiveKit
import SwiftUI

/// The entire voice+vision client, post-migration: join a LiveKit room, publish
/// mic and camera, subscribe to the agent's audio. Everything the direct
/// connection hand-rolled -- echo cancellation, interruption, turn-taking,
/// reconnection -- lives in WebRTC and the server-side agent now. What remains
/// on the phone is a room ticket and two track toggles.
@MainActor
final class LiveKitSession: NSObject, ObservableObject {
  enum State: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
  }

  /// What the agent is doing right now, surfaced so a dead worker is visible
  /// instead of an empty room that politely ignores you. Driven by agent
  /// presence in the room plus the standard `lk.agent.state` attribute the
  /// agents framework publishes (listening / thinking / speaking).
  enum AgentStatus: Equatable {
    case none        // no active call
    case waiting     // call is up, agent hasn't joined the room
    case starting    // agent joined, model session still initializing
    case listening
    case thinking
    case speaking
    case left        // agent was here and disconnected mid-call
  }

  @Published private(set) var state: State = .disconnected
  @Published private(set) var agentStatus: AgentStatus = .none

  /// True when this call's video comes from the glasses (DAT bridge) instead
  /// of the phone camera. Decided at start() from the persisted capture source.
  @Published private(set) var usingGlassesSource = false

  /// Live caption from the transcription text streams (agent and user speech).
  struct Caption: Equatable {
    let text: String
    let isAgent: Bool
  }

  @Published private(set) var caption: Caption?
  private var captionClearTask: Task<Void, Never>?

  /// A typed card from the agent's show_card tool (vc.ui topic). One card at a
  /// time; the same uuid replaces content in place; dismissal sticks until the
  /// agent publishes again.
  struct UICard: Equatable {
    struct Fact: Equatable {
      let label: String
      let value: String
    }

    struct Item: Equatable {
      let glyph: String?
      let title: String
      let subtitle: String?
      let trailing: String?
    }

    let uuid: String
    let type: String
    let title: String?
    let value: String?
    let body: String?
    let facts: [Fact]
    let items: [Item]
    let imageURL: String?
    let fallbackText: String
  }

  @Published private(set) var card: UICard?

  func dismissCard() {
    card = nil
  }
  @Published private(set) var localVideoTrack: LocalVideoTrack?
  /// Camera-only preview while no call is active. The camera IS this app;
  /// hanging up stops the listening, not the seeing.
  @Published private(set) var previewTrack: LocalVideoTrack?

  let room = Room()

  override init() {
    super.init()
    room.add(delegate: self)
  }

  var isActive: Bool { state == .connected || state == .connecting }

  /// Fields to attach to the next `start()`. Set by `LiveKitInterceptor` before
  /// dialling and cleared by it afterwards, so an ordinary call is unaffected.
  var pendingSessionContext: [String: String]?
  var missionWorkerIdentity: String?
  var missionCaptureSource: CaptureSource?
  var missionEngine: IntelligenceEngine?
  private var lifecycleGeneration = 0
  var missionTransportConnected: Bool { room.connectionState == .connected }
  var missionFrame: UIImage? { frameGrabber.latestImage() }
  var hasFreshMissionFrame: Bool { frameGrabber.isFresh }
  private var selectedSource: CaptureSource { missionCaptureSource ?? SettingsManager.shared.captureSource }

  func refreshAgentStatus() {
    guard state == .connected else {
      agentStatus = .none
      return
    }
    guard let agent = room.remoteParticipants.values.first(where: { $0.isAgent }) else {
      if agentStatus != .left { agentStatus = .waiting }
      return
    }
    switch agent.agentState {
    case .idle, .initializing: agentStatus = .starting
    case .listening: agentStatus = .listening
    case .thinking: agentStatus = .thinking
    case .speaking: agentStatus = .speaking
    }
  }

  // MARK: - Freeze (pin a frame for the model to refer to)

  /// While set, the screen shows this frame and the published video is muted:
  /// the model receives no newer frames, so the pinned one stays the most
  /// recent thing it has seen -- "this" means the frame the user pinned.
  @Published private(set) var frozenFrame: UIImage?

  private let frameGrabber = LatestFrameGrabber()
  private var grabberTrack: LocalVideoTrack?

  /// Every frame the phone camera captures, with the rotation that makes it
  /// upright. Called on the capture thread.
  ///
  /// The watcher rides this in phone mode. In glasses mode it rides the DAT
  /// decoder instead, and the local track here is the buffer track fed by
  /// `pushGlassesFrame` -- forwarding that too would hand the watcher every
  /// glasses frame twice, so this stays nil while the glasses are the source.
  var onPhoneFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)? {
    didSet { syncFrameForwarding() }
  }

  private func syncFrameForwarding() {
    frameGrabber.onFrame = usingGlassesSource ? nil : onPhoneFrame
  }

  private func attachGrabber(to track: LocalVideoTrack?) {
    if let old = grabberTrack { old.remove(videoRenderer: frameGrabber) }
    grabberTrack = track
    // Both callers decide `usingGlassesSource` before building the track, so
    // this is the moment the forwarding decision is known.
    syncFrameForwarding()
    if let track { track.add(videoRenderer: frameGrabber) }
  }

  func toggleFreeze() async {
    if frozenFrame != nil {
      await unfreeze()
    } else {
      await freeze()
    }
  }

  func freeze() async {
    guard frozenFrame == nil, let image = frameGrabber.latestImage() else { return }
    frozenFrame = image
    if state == .connected {
      if let pub = room.localParticipant.localVideoTracks.first {
        try? await pub.mute()
      }
    }
  }

  func unfreeze() async {
    guard frozenFrame != nil else { return }
    frozenFrame = nil
    if state == .connected {
      if let pub = room.localParticipant.localVideoTracks.first {
        try? await pub.unmute()
      }
    }
  }

  // MARK: - Zoom

  /// Optical-then-digital zoom applied at the sensor through whichever camera
  /// track is live (call or preview), so what you pinch into is what the model
  /// sees. Capped at 8x: past that the wide lens is upscaling, not resolving.
  @Published private(set) var zoomFactor: CGFloat = 1
  private var zoomAtGestureStart: CGFloat = 1

  private var activeCaptureDevice: AVCaptureDevice? {
    let track = localVideoTrack ?? previewTrack
    return (track?.capturer as? CameraCapturer)?.device
  }

  func beginZoomGesture() {
    zoomAtGestureStart = zoomFactor
  }

  func updateZoom(scale: CGFloat) {
    guard let device = activeCaptureDevice else { return }
    let ceiling = min(device.activeFormat.videoMaxZoomFactor, 8)
    let target = min(max(zoomAtGestureStart * scale, 1), ceiling)
    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = target
      device.unlockForConfiguration()
      zoomFactor = target
    } catch {
      NSLog("[LiveKit] zoom failed: %@", error.localizedDescription)
    }
  }

  /// Hardware zoom resets whenever the camera changes hands (preview <-> call).
  private func resetZoom() {
    zoomFactor = 1
    zoomAtGestureStart = 1
  }

  /// Local, unpublished camera so the screen shows the world before and
  /// between calls. Handed off to the room on connect (one owner at a time).
  func startPreview() async {
    // A preview built for the other capture source is worse than no preview at
    // all. The glasses render through `glassesCapturerBox`, which only a buffer
    // track wires up; a camera track leaves it nil, so DAT frames arrive via
    // pushGlassesFrame and are dropped on the floor. The screen stays black
    // while the watcher, which rides `onAnalysisFrame` instead, keeps detecting
    // perfectly -- so the stream looks dead and is not.
    //
    // This happens on the ordinary path: the preview opens on the phone camera
    // before anyone visits Settings, and `stop()` calls straight back here
    // without clearing `previewTrack`, so the guard below returns early forever
    // and the glasses track is never built.
    if previewTrack != nil, (selectedSource == .glasses) != usingGlassesSource {
      await stopPreview()
    }
    guard state == .disconnected || isFailed, previewTrack == nil else { return }
    let track: LocalVideoTrack
    // Otherwise only set in start(); without it a call-free preview renders
    // neither frames nor the waiting placeholder, just black.
    usingGlassesSource = selectedSource == .glasses
    if selectedSource == .glasses {
      // Glasses preview is a buffer track fed by pushGlassesFrame; there is
      // no capture device to open.
      track = LocalVideoTrack.createBufferTrack(name: "glasses-preview", source: .camera)
      glassesCapturerBox.capturer = track.capturer as? BufferCapturer
    } else {
      track = LocalVideoTrack.createCameraTrack(
        options: CameraCaptureOptions(position: .back))
      glassesCapturerBox.capturer = nil
    }
    do {
      try await track.start()
      previewTrack = track
      attachGrabber(to: track)
    } catch {
      NSLog("[LiveKit] preview camera unavailable: %@", error.localizedDescription)
    }
  }

  /// Holds the live glasses BufferCapturer outside actor isolation: frames
  /// arrive at 24fps from the DAT decoder's context, and a per-frame hop to
  /// the main actor would be pure overhead. BufferCapturer.capture is
  /// thread-safe; a stale capturer after track teardown drops frames harmlessly.
  private final class GlassesCapturerBox: @unchecked Sendable {
    var capturer: BufferCapturer?
    var sawFrame = false
  }

  /// Flips on the first glasses frame; the call screen shows its waiting
  /// placeholder until then.
  @Published private(set) var hasGlassesFrame = false

  private let glassesCapturerBox = GlassesCapturerBox()

  /// Glasses frames from the DAT decoder land here and flow into whichever
  /// buffer track is live (call or preview). Freeze works unchanged: muting
  /// the publication stops delivery to the room while the grabber holds the
  /// pinned frame.
  nonisolated func pushGlassesFrame(_ pixelBuffer: CVPixelBuffer) {
    glassesCapturerBox.capturer?.capture(pixelBuffer)
    if !glassesCapturerBox.sawFrame {
      glassesCapturerBox.sawFrame = true
      Task { @MainActor in self.hasGlassesFrame = true }
    }
  }

  private func stopPreview() async {
    if let track = previewTrack {
      previewTrack = nil
      try? await track.stop()
    }
  }

  func start() async {
    guard state == .disconnected || isFailed else { return }
    guard GeminiConfig.isAgentConfigured else {
      state = .failed("Gateway not configured. Check Settings.")
      return
    }
    lifecycleGeneration += 1
    let generation = lifecycleGeneration
    state = .connecting
    await stopPreview()
    guard generation == lifecycleGeneration, !Task.isCancelled else { return }

    usingGlassesSource = selectedSource == .glasses

    // Named so a failure says which call threw. These three fail in completely
    // different places -- the token endpoint, the room, the microphone -- and
    // collapse into one `error.localizedDescription` that names none of them.
    // "Invalid state(connectionState is .disconnected)" in particular reads the
    // same whether the room never connected or dropped straight after.
    var stage = "ticket"
    do {
      let ticket = try await fetchTicket()
      guard generation == lifecycleGeneration, !Task.isCancelled else { return }
      if pendingSessionContext?["mode"] == "mission" {
        guard ticket.missionVersion == 1, let identity = ticket.workerIdentity, !identity.isEmpty else {
          throw NSError(domain: "Mission", code: 1, userInfo: [NSLocalizedDescriptionKey: "This gateway does not support mission protocol v1. Update the gateway and worker."])
        }
        missionWorkerIdentity = identity
      }
      // Before connect, not after: the worker is dispatched at room creation
      // and starts talking as soon as it sees a participant, so a handler
      // registered further down -- behind mic setup and a published video
      // track -- reliably missed the opening line. Registration is a local
      // dictionary write and needs no connection.
      await registerCaptionHandler()
      await registerCardHandler()
      await registerTranscriptHandler()
      guard generation == lifecycleGeneration, !Task.isCancelled else { return }
      stage = "connect"
      try await room.connect(url: ticket.url, token: ticket.token)
      guard generation == lifecycleGeneration, !Task.isCancelled else { await room.disconnect(); return }
      stage = "microphone"
      try await room.localParticipant.setMicrophone(enabled: true)
      guard generation == lifecycleGeneration, !Task.isCancelled else { await room.disconnect(); return }
      // Camera failure (simulator, permission denied) degrades to voice-only
      // rather than killing the call.
      do {
        if usingGlassesSource {
          // Glasses frames arrive via pushGlassesFrame; publish a buffer
          // track with camera source so mute/freeze/agent logic is identical.
          let track = LocalVideoTrack.createBufferTrack(name: "glasses", source: .camera)
          // Wired before the track starts, exactly as startPreview does it. A
          // buffer track has no camera to open: until something pushes into
          // its capturer it has no frames and no dimensions, so publishing
          // first means publishing an empty track. That published as black --
          // in the room and on the screen -- while DAT frames kept arriving
          // and going nowhere, because the box was still pointing at the
          // preview capturer this track replaces.
          glassesCapturerBox.capturer = track.capturer as? BufferCapturer
          try await track.start()
          guard generation == lifecycleGeneration, !Task.isCancelled else { try? await track.stop(); return }
          // Explicit encoding, because the SDK's default for a 720-tall track
          // caps the encoder at 1.7 Mbps and publishes three simulcast layers.
          // In mission mode nothing but the recorder ever subscribes to this
          // track, so the two lower layers are wasted CPU and uplink, and the
          // bitrate cap was the tightest hop in the pipeline after Bluetooth.
          // Maintain resolution: when the uplink dips, drop frames rather than
          // blur the labels the recording exists to capture. Keep in step with
          // the egress bitrate in agent/corvus_mission_storage.py, which
          // re-encodes this track and cannot add back what is lost here.
          let publishOptions = VideoPublishOptions(
            encoding: VideoEncoding(maxBitrate: 4_000_000, maxFps: 24),
            simulcast: false,
            degradationPreference: .maintainResolution)
          _ = try await room.localParticipant.publish(videoTrack: track, options: publishOptions)
          localVideoTrack = track
        } else {
          // A video-call SDK defaults to the selfie camera; this app is a pair
          // of eyes on the world, so it opens on the back camera.
          try await room.localParticipant.setCamera(
            enabled: true,
            captureOptions: CameraCaptureOptions(position: .back))
          localVideoTrack = room.localParticipant.localVideoTracks
            .compactMap { $0.track as? LocalVideoTrack }
            .first
        }
        attachGrabber(to: localVideoTrack)
        CorvusLog.shared.append(.init(
          kind: "video_published", at: Date(),
          note: usingGlassesSource ? "glasses buffer track" : "phone back camera"))
      } catch {
        NSLog("[LiveKit] camera unavailable, voice-only: %@", error.localizedDescription)
        // Recorded, not just printed: this branch is silent from the outside --
        // the call carries on, the intercept sounds normal, and the only
        // evidence is a room with no video in it.
        CorvusLog.shared.append(.init(
          kind: "video_publish_failed", at: Date(),
          error: error.localizedDescription,
          note: usingGlassesSource ? "glasses buffer track" : "phone back camera"))
      }
      guard generation == lifecycleGeneration, !Task.isCancelled else { await stop(restartPreview: false); return }
      state = .connected
      resetZoom()
      refreshAgentStatus()
    } catch {
      // The stage, not just the message: an intercept that aborts here leaves
      // no turns and no room, so this line is the only account of what went
      // wrong. The room's own view of its connection is recorded too, because
      // "disconnected" at the microphone step means it dropped after connect
      // returned, which is a different bug from never connecting at all.
      CorvusLog.shared.append(.init(
        kind: "livekit_connect_failed", at: Date(),
        error: error.localizedDescription,
        note: "stage=\(stage) connectionState=\(room.connectionState)"))
      guard generation == lifecycleGeneration, !Task.isCancelled else { return }
      state = .failed("\(stage): \(error.localizedDescription)")
      agentStatus = .none
      await room.disconnect()
      // Even a failed call leaves the user with eyes.
      if pendingSessionContext?["mode"] != "mission" { await startPreview() }
    }
  }

  func stop(restartPreview: Bool = true) async {
    lifecycleGeneration += 1
    await stopCapture()
    await room.disconnect()
    localVideoTrack = nil
    state = .disconnected
    agentStatus = .none
    resetZoom()
    frozenFrame = nil
    caption = nil
    captionClearTask?.cancel()
    card = nil
    glassesCapturerBox.sawFrame = false
    hasGlassesFrame = false
    if restartPreview { await startPreview() }
  }

  func stopCapture() async {
    lifecycleGeneration += 1
    // Silence subscribed agent speech before awaiting any network cleanup.
    for participant in room.remoteParticipants.values {
      for publication in participant.audioTracks {
        (publication.track as? RemoteAudioTrack)?.volume = 0
      }
    }
    attachGrabber(to: nil)
    frameGrabber.clear()
    glassesCapturerBox.capturer = nil
    try? await room.localParticipant.setMicrophone(enabled: false)
    if let track = localVideoTrack { try? await track.stop() }
    await stopPreview()
  }

  // MARK: - Captions (transcription text streams)

  /// The agents framework publishes live transcriptions of both sides on the
  /// "lk.transcription" topic; each utterance segment is one stream, growing
  /// chunk by chunk. Registration is per-room and survives reconnects, so a
  /// second register on redial throws -- ignored deliberately.
  private func registerCaptionHandler() async {
    do {
      try await room.registerTextStreamHandler(for: "lk.transcription") { [weak self] reader, identity in
        let isAgent = identity.stringValue.hasPrefix("agent")
        var text = ""
        for try await chunk in reader {
          text += chunk
          await self?.showCaption(text, isAgent: isAgent)
        }
      }
    } catch {
      // Handlers are per-room and survive reconnects, so a redial throws
      // "already registered" -- which is the desired state, not a failure.
      NSLog("[LiveKit] caption handler: %@", error.localizedDescription)
    }
  }

  /// The agent's own transcript of the intercept, as JSON, published just
  /// before it tears the room down.
  var onTranscript: ((String) -> Void)?

  private func registerTranscriptHandler() async {
    do {
      try await room.registerTextStreamHandler(for: "corvus.transcript") { [weak self] reader, _ in
        let json = try await reader.readAll()
        await MainActor.run { self?.onTranscript?(json) }
      }
    } catch {
      NSLog("[LiveKit] transcript handler: %@", error.localizedDescription)
    }
  }

  private func registerCardHandler() async {
    do {
      try await room.registerTextStreamHandler(for: "vc.ui") { [weak self] reader, _ in
        let json = try await reader.readAll()
        await self?.handleCardJSON(json)
      }
    } catch {
      NSLog("[LiveKit] card handler: %@", error.localizedDescription)
    }
  }

  private func handleCardJSON(_ json: String) {
    guard let data = json.data(using: .utf8),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let uuid = dict["uuid"] as? String,
          let type = dict["type"] as? String
    else {
      NSLog("[LiveKit] ignoring malformed card payload (%d bytes)", json.count)
      return
    }
    let facts = ((dict["facts"] as? [[String: Any]]) ?? []).compactMap { f -> UICard.Fact? in
      guard let label = f["label"] as? String, let value = f["value"] as? String else { return nil }
      return UICard.Fact(label: label, value: value)
    }
    let items = ((dict["items"] as? [[String: Any]]) ?? []).compactMap { i -> UICard.Item? in
      guard let title = i["title"] as? String else { return nil }
      return UICard.Item(
        glyph: i["glyph"] as? String,
        title: title,
        subtitle: i["subtitle"] as? String,
        trailing: i["trailing"] as? String)
    }
    card = UICard(
      uuid: uuid,
      type: type,
      title: dict["title"] as? String,
      value: dict["value"] as? String,
      body: dict["body"] as? String,
      facts: facts,
      items: items,
      imageURL: dict["image_url"] as? String,
      fallbackText: (dict["fallback_text"] as? String) ?? "")
  }

  private func showCaption(_ text: String, isAgent: Bool) {
    guard !text.isEmpty, SettingsManager.shared.showCaptions else { return }
    caption = Caption(text: text, isAgent: isAgent)
    captionClearTask?.cancel()
    captionClearTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      if !Task.isCancelled { self?.caption = nil }
    }
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  // MARK: - Room ticket

  private struct Ticket: Decodable {
    let url: String
    let room: String
    let token: String
    let missionVersion: Int?
    let workerIdentity: String?
  }

  /// The gateway holds the LiveKit secret and mints a short-lived per-user
  /// room JWT. The engine choice (which realtime model answers) rides along
  /// and comes back inside the token as participant metadata for the worker.
  private func fetchTicket() async throws -> Ticket {
    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/livekit-token") else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var payload: [String: Any] = [
      "engine": (missionEngine ?? SettingsManager.shared.intelligenceEngine).rawValue
    ]
    // Corvus rides along here: the token endpoint copies this into the room
    // token's participant metadata, which the worker already reads. Sending the
    // interceptor's whole instruction text rather than a study id keeps the
    // research instrument on the phone, where the study lives, instead of
    // splitting it across a Python worker that would then need its own copy.
    if let context = pendingSessionContext {
      var metadata: [String: Any] = context
      if context["mode"] == "mission" { metadata["version"] = 1 }
      payload["corvus"] = metadata
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let detail = OpenClawBridge.errorMessage(from: data) ?? "gateway error"
      throw NSError(domain: "LiveKitSession", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return try JSONDecoder().decode(Ticket.self, from: data)
  }
}


// Room events arrive on SDK threads; each handler hops to the main actor and
// re-derives agent status from the room, so ordering races collapse into
// "recompute from current truth".
extension LiveKitSession: RoomDelegate {
  nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
    Task { @MainActor in self.refreshAgentStatus() }
  }

  nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
    let agentLeft = participant.isAgent
    Task { @MainActor in
      if agentLeft, self.state == .connected {
        self.agentStatus = .left
      } else {
        self.refreshAgentStatus()
      }
    }
  }

  nonisolated func room(
    _ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]
  ) {
    guard participant.isAgent else { return }
    Task { @MainActor in self.refreshAgentStatus() }
  }

  /// A room can end from the server side -- an intercept worker calling
  /// DeleteRoom when it is finished, an admin, a cloud failover. Without this
  /// the app kept reporting `connected` for a room that no longer existed, and
  /// anything waiting on the call to finish waited until its own timeout.
  nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
    Task { @MainActor in
      guard self.state != .disconnected else { return }
      if let error {
        self.state = .failed(error.localizedDescription)
      } else {
        self.state = .disconnected
      }
      self.agentStatus = .none
    }
  }
}

/// Keeps the most recent video frame so a freeze can pin exactly what was on
/// screen. Conversion to UIImage happens only when a pin is taken.
final class LatestFrameGrabber: VideoRenderer {
  private let lock = NSLock()
  private var latestFrame: VideoFrame?
  private var receivedAt: Double = 0
  var isFresh: Bool { lock.lock(); defer { lock.unlock() }; return receivedAt > 0 && ProcessInfo.processInfo.systemUptime - receivedAt < 6 }
  func clear() { lock.lock(); latestFrame = nil; receivedAt = 0; lock.unlock() }
  private var _onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?

  /// Live tap on the track, for the watcher. Set from the main actor, read on
  /// the capture thread, hence the lock.
  var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)? {
    get { lock.lock(); defer { lock.unlock() }; return _onFrame }
    set { lock.lock(); _onFrame = newValue; lock.unlock() }
  }

  var isAdaptiveStreamEnabled: Bool { false }
  var adaptiveStreamSize: CGSize { .zero }

  func set(size: CGSize) {}

  func render(frame: VideoFrame) {
    lock.lock()
    latestFrame = frame
    receivedAt = ProcessInfo.processInfo.systemUptime
    let onFrame = _onFrame
    lock.unlock()
    // Camera frames wrap a CVPixelBuffer already, so this is an unwrap, not a
    // conversion. The watcher's own sampler throttles downstream.
    guard let onFrame, let pixelBuffer = frame.toCVPixelBuffer() else { return }
    onFrame(pixelBuffer, Self.orientation(for: frame.rotation))
  }

  static func orientation(for rotation: VideoRotation) -> CGImagePropertyOrientation {
    switch rotation {
    case ._90: return .right
    case ._180: return .down
    case ._270: return .left
    default: return .up
    }
  }

  func render(frame: VideoFrame, captureDevice: AVCaptureDevice?, captureOptions: VideoCaptureOptions?) {
    render(frame: frame)
  }

  func latestImage() -> UIImage? {
    lock.lock()
    let frame = latestFrame
    lock.unlock()
    guard let frame, let pixelBuffer = frame.toCVPixelBuffer() else { return nil }
    // The sensor delivers landscape buffers; renderers apply the frame's
    // rotation tag at display time. Converting raw pixels skips that step, so
    // apply it here or every portrait pin comes out sideways.
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      .oriented(Self.orientation(for: frame.rotation))
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
