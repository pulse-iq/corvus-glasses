import Foundation
import UIKit

/// What the phone tells the gateway about the next call. Copied into the
/// room token's participant metadata under "corvus", where the worker reads
/// it; `source` and `engine` override Settings for this one call.
struct RealtimeCallContext: Equatable {
  var metadata: [String: String]
  var source: CaptureSource? = nil
  var engine: IntelligenceEngine? = nil
  var isMission: Bool { metadata["mode"] == "mission" }
}

enum RealtimeLinkState: Equatable {
  case disconnected, connecting, connected
  case failed(String)
}

/// Whether the worker is in the room. The mission cares about "gone", the
/// intercept about "arrived"; neither cares what the model is doing.
enum RealtimeAgentPresence: Equatable {
  case absent, waiting, present, left
}

/// The realtime call as Corvus sees it: a room with a worker in it that
/// carries the microphone, the glasses video, and text streams both ways.
///
/// This is the seam between Corvus and VisionClaw's `LiveKitSession`. Mission
/// and intercept code talk only to this protocol; `LiveKitRealtimeMedia.swift`
/// maps it onto whatever upstream currently calls things, so a pull from
/// upstream touches that one file and not the mission logic.
@MainActor
protocol RealtimeMedia: AnyObject {
  var callContext: RealtimeCallContext? { get set }
  var linkState: RealtimeLinkState { get }
  var agentPresence: RealtimeAgentPresence { get }
  /// Participant identity of the worker the gateway dispatched, from the ticket.
  var workerIdentity: String? { get }
  var isTransportConnected: Bool { get }
  /// "glasses" or "phone" while a video track is published; nil when the call
  /// is voice-only, which is the signature of a recording that is a black box.
  var videoSource: String? { get }
  var latestFrame: UIImage? { get }
  var hasFreshFrame: Bool { get }
  /// The worker's own transcript JSON, published just before it leaves.
  var onTranscript: ((String) -> Void)? { get set }

  func connect() async
  func stopCapture() async
  func disconnect(restartPreview: Bool) async
  /// Delivers each complete text stream on `topic` with its sender identity.
  /// Streams larger than `maxBytes` are dropped, not truncated.
  func receiveText(topic: String, maxBytes: Int,
                   handler: @escaping @Sendable (String, String) async -> Void) async throws
  func sendText(_ text: String, topic: String) async throws
}
