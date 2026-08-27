import Foundation

/// What one vision call concluded about one frame.
struct Detection: Equatable, Codable {
  /// True when the wearer appears to be holding a product -- any product, not
  /// necessarily one we care about. Kept separate from `itemID` so the logs can
  /// tell "held something we don't track" apart from "held nothing", which are
  /// very different prompt-tuning problems.
  let holding: Bool
  /// The matched watchlist id, or nil when nothing on the list is being held.
  let itemID: String?
  /// The model's own free-text guess at the product. Diagnostic only -- useful
  /// when itemID is nil and we want to know what it saw instead.
  let productGuess: String?
  let confidence: Double

  static let empty = Detection(holding: false, itemID: nil, productGuess: nil, confidence: 0)
}

/// One detector call, with everything the benchmark needs to compare backends.
struct DetectionOutcome {
  let detection: Detection
  let latency: TimeInterval
  /// Raw model text, kept for debugging JSON-shape failures.
  let rawResponse: String
  let detectorName: String
}

enum DetectorError: Error, LocalizedError {
  case notConfigured(String)
  case transport(String)
  case badStatus(Int, String)
  case unparseable(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured(let who): return "\(who) has no API key configured"
    case .transport(let m): return "network error: \(m)"
    case .badStatus(let code, let body): return "HTTP \(code): \(body.prefix(300))"
    case .unparseable(let body): return "could not parse model output: \(body.prefix(300))"
    }
  }
}

/// A swappable Stage 1 vision backend. One JPEG in, one structured verdict out.
/// Everything behind this protocol is a single HTTP call, which is what makes
/// cross-model benchmarking cheap.
protocol ProductDetector: Sendable {
  /// Stable, human-readable identifier that lands in the logs.
  var name: String { get }
  var isConfigured: Bool { get }
  func detect(jpeg: Data, study: Study) async throws -> DetectionOutcome
}

/// The backends we can benchmark against each other. Model ids live in
/// `CorvusConfig` so they can be re-pointed without touching this enum.
enum DetectorKind: String, CaseIterable, Identifiable, Codable {
  case geminiFlashLite
  case geminiFlash
  case openAIMini
  case claudeHaiku

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .geminiFlashLite: return "Gemini Flash-Lite"
    case .geminiFlash: return "Gemini Flash"
    case .openAIMini: return "OpenAI mini"
    case .claudeHaiku: return "Claude Haiku"
    }
  }

  func make() -> ProductDetector {
    switch self {
    case .geminiFlashLite: return GeminiProductDetector(model: CorvusConfig.geminiFlashLiteModel)
    case .geminiFlash: return GeminiProductDetector(model: CorvusConfig.geminiFlashModel)
    case .openAIMini: return OpenAIProductDetector(model: CorvusConfig.openAIVisionModel)
    case .claudeHaiku: return AnthropicProductDetector(model: CorvusConfig.anthropicVisionModel)
    }
  }
}

// MARK: - Shared response parsing

enum DetectionParser {
  /// Models wrap JSON in prose or fences no matter how firmly the prompt asks
  /// them not to, so pull the first balanced object out rather than trusting
  /// the whole body to be JSON.
  static func parse(_ text: String, watchlist: [WatchItem]) throws -> Detection {
    guard let json = firstJSONObject(in: text),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw DetectorError.unparseable(text)
    }

    let holding = (obj["holding"] as? Bool) ?? false
    let confidence = (obj["confidence"] as? Double)
      ?? (obj["confidence"] as? NSNumber)?.doubleValue
      ?? 0

    // The model is asked for an id from the list, but it will occasionally
    // return the display name, a near-miss slug, or the string "null". Resolve
    // against the watchlist and drop anything that does not land on a real item
    // -- an unresolvable id must never reach the trigger machine.
    let rawID = (obj["item_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    var itemID: String?
    if let rawID, !rawID.isEmpty, rawID.lowercased() != "null", rawID.lowercased() != "none" {
      if let match = Watchlist.item(withID: rawID, in: watchlist) {
        itemID = match.id
      } else if let byName = watchlist.first(where: {
        $0.displayName.caseInsensitiveCompare(rawID) == .orderedSame
      }) {
        itemID = byName.id
      }
    }

    let guess = (obj["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return Detection(
      holding: holding,
      itemID: itemID,
      productGuess: (guess?.isEmpty == false) ? guess : nil,
      confidence: min(max(confidence, 0), 1))
  }

  /// Scan for the first `{`, then walk to its matching `}` while ignoring
  /// braces inside string literals.
  static func firstJSONObject(in text: String) -> String? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    var i = start
    while i < text.endIndex {
      let c = text[i]
      if escaped {
        escaped = false
      } else if c == "\\" && inString {
        escaped = true
      } else if c == "\"" {
        inString.toggle()
      } else if !inString {
        if c == "{" { depth += 1 }
        if c == "}" {
          depth -= 1
          if depth == 0 { return String(text[start...i]) }
        }
      }
      i = text.index(after: i)
    }
    return nil
  }
}
