import Foundation
import UIKit

/// Local, append-only session log.
///
/// Deliberately files on the phone rather than a backend: Corvus's own API is
/// not in this loop yet, and a proof of concept should not need a network to
/// keep its data. One JSONL file per app launch, plus an optional frame corpus
/// for offline detector benchmarking.
final class CorvusLog {
  static let shared = CorvusLog()

  /// One row in the log. `kind` discriminates; the optional fields carry
  /// whatever that kind needs. Flat on purpose -- JSONL is meant to be greppable
  /// and loadable into a dataframe without a schema library.
  struct Row: Codable {
    let kind: String
    let at: Date
    var detector: String?
    var latencyMS: Int?
    var holding: Bool?
    var itemID: String?
    var productGuess: String?
    var confidence: Double?
    var decision: String?
    var framePath: String?
    var error: String?
    var note: String?
  }

  private let queue = DispatchQueue(label: "com.corvus.log")
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys]
    return e
  }()

  private(set) var sessionDirectory: URL
  private var logURL: URL

  private init() {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("corvus", isDirectory: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    sessionDirectory = root.appendingPathComponent("session-\(stamp)", isDirectory: true)
    logURL = sessionDirectory.appendingPathComponent("events.jsonl")
    try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
  }

  func append(_ row: Row) {
    queue.async { [self] in
      guard var line = try? encoder.encode(row) else { return }
      line.append(0x0A)  // newline
      if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
      } else {
        try? line.write(to: logURL, options: .atomic)
      }
    }
  }

  /// Persist a sampled frame next to its verdict. This is how the offline
  /// benchmark corpus gets built -- run a shopping trip with capture on, pull
  /// the directory off the phone, then replay it against every detector.
  func saveFrame(_ jpeg: Data, tag: String) -> String? {
    let name = "\(tag)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
    let url = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let fileURL = url.appendingPathComponent(name)
    guard (try? jpeg.write(to: fileURL, options: .atomic)) != nil else { return nil }
    return "frames/\(name)"
  }
}
