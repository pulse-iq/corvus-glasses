import Foundation
import LiveKit
import UIKit

/// The one place Corvus reads VisionClaw's `LiveKitSession`. When upstream
/// renames a state or reshapes a call, this file changes and the mission code
/// does not. `callContext`, `workerIdentity`, `onTranscript` and `stopCapture`
/// are stored on the session itself, because `start()` reads them.
extension LiveKitSession: RealtimeMedia {
  var linkState: RealtimeLinkState {
    switch state {
    case .disconnected: return .disconnected
    case .connecting: return .connecting
    case .connected: return .connected
    case .failed(let why): return .failed(why)
    }
  }

  var agentPresence: RealtimeAgentPresence {
    switch agentStatus {
    case .none: return .absent
    case .waiting: return .waiting
    case .starting, .listening, .thinking, .speaking: return .present
    case .left: return .left
    }
  }

  var isTransportConnected: Bool { room.connectionState == .connected }

  var videoSource: String? {
    localVideoTrack == nil ? nil : (usingGlassesSource ? "glasses" : "phone")
  }

  var latestFrame: UIImage? { latestGrabbedFrame }
  var hasFreshFrame: Bool { hasFreshGrabbedFrame }

  func connect() async { await start() }

  func disconnect(restartPreview: Bool) async { await stop(restartPreview: restartPreview) }

  func receiveText(topic: String, maxBytes: Int,
                   handler: @escaping @Sendable (String, String) async -> Void) async throws {
    try await room.registerTextStreamHandler(for: topic) { reader, identity in
      var text = ""
      for try await chunk in reader {
        text += chunk
        guard text.utf8.count <= maxBytes else { return }
      }
      await handler(text, identity.stringValue)
    }
  }

  func sendText(_ text: String, topic: String) async throws {
    _ = try await room.localParticipant.sendText(text, options: StreamTextOptions(topic: topic))
  }
}
