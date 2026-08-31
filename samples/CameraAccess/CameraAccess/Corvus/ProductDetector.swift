import Foundation

/// One product the wearer has in hand.
struct HeldProduct: Equatable, Codable {
  /// The matched watchlist id, when it is one of the named products.
  let itemID: String?
  /// The matched section id. Set independently of `itemID`: a shop cannot be
  /// enumerated, so "a yogurt, not one of ours" is a useful and common answer.
  let categoryID: String?
  /// The model's own free-text guess at the product. Diagnostic, and what an
  /// intercept uses to name the actual bottle rather than the category.
  let productGuess: String?
  /// Held up close with the label toward the camera -- reading, not carrying.
  /// A single frame can tell these apart, and they deserve different questions.
  let examining: Bool
  let confidence: Double

  init(
    itemID: String? = nil, categoryID: String? = nil, productGuess: String? = nil,
    examining: Bool = false, confidence: Double
  ) {
    self.itemID = itemID
    self.categoryID = categoryID
    self.productGuess = productGuess
    self.examining = examining
    self.confidence = confidence
  }

  func matches(_ target: WatchTarget) -> Bool {
    switch target {
    case .item(let id): return itemID?.caseInsensitiveCompare(id) == .orderedSame
    case .category(let id): return categoryID?.caseInsensitiveCompare(id) == .orderedSame
    }
  }
}

/// The shelf section filling the near field: the wearer is standing at it, not
/// walking past it.
struct ShelfFacing: Equatable, Codable {
  let categoryID: String
  let confidence: Double
}

/// Where the frame was taken. Coarse on purpose -- it exists to keep a question
/// from arriving at the till, not to localise anyone.
enum SceneKind: String, Equatable, Codable {
  case aisle, cart, checkout, other
}

/// What one vision call saw. Facts, no judgement.
///
/// Deliberately not "is the wearer browsing" or "should we interrupt": those
/// are properties of a sequence, and a frame cannot answer them. Everything
/// here is answerable from one image, and the primitives in
/// `TriggerPrimitives` compose these facts into the questions that are not.
struct Observation: Equatable, Codable {
  /// Empty is the common case, and is not the same as an absent observation.
  let held: [HeldProduct]
  let facing: ShelfFacing?
  let scene: SceneKind

  init(held: [HeldProduct] = [], facing: ShelfFacing? = nil, scene: SceneKind = .other) {
    self.held = held
    self.facing = facing
    self.scene = scene
  }

  static let empty = Observation()

  var isHolding: Bool { !held.isEmpty }

  /// Products the wearer is holding that the study has no name for. The number
  /// to watch while tuning: a watchlist that misses what people actually pick
  /// up produces a silent trip, and this is the only place that shows it.
  var unmatched: [HeldProduct] {
    held.filter { $0.itemID == nil && $0.categoryID == nil }
  }

  func held(matching target: WatchTarget) -> [HeldProduct] {
    held.filter { $0.matches(target) }
  }

  /// Whether this frame concerns the target at all, by either route. Used to
  /// decide whether a cooldown is worth reporting -- "cooling down" is only
  /// interesting when the thing it is suppressing is actually in view.
  func mentions(_ target: WatchTarget) -> Bool {
    if !held(matching: target).isEmpty { return true }
    if case .category(let id) = target {
      return facing?.categoryID.caseInsensitiveCompare(id) == .orderedSame
    }
    return false
  }
}

/// One detector call, with everything the benchmark needs to compare backends.
struct DetectionOutcome {
  let observation: Observation
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

/// A swappable vision backend for the watcher. One JPEG in, one verdict out.
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
  static func parse(_ text: String, study: Study) throws -> Observation {
    guard let json = firstJSONObject(in: text),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw DetectorError.unparseable(text)
    }

    let held = (obj["held"] as? [[String: Any]] ?? []).compactMap { entry -> HeldProduct? in
      let guess = string(entry["product"])
      let itemID = resolveItem(string(entry["item_id"]), in: study.items)
      // An item resolves its own section, so a model that names the product but
      // forgets the category still lands in the right place.
      let ownCategory = itemID.flatMap { Watchlist.item(withID: $0, in: study.items)?.categoryID }
      let categoryID = resolveCategory(string(entry["category_id"]), in: study.categories)
        ?? ownCategory
      let confidence = clamp(number(entry["confidence"]))
      // A product with no id, no section and no guess is not an observation of
      // anything; keeping it would inflate `held` with empty rows.
      guard itemID != nil || categoryID != nil || guess != nil else { return nil }
      return HeldProduct(
        itemID: itemID,
        categoryID: categoryID,
        productGuess: guess,
        examining: (entry["examining"] as? Bool) ?? false,
        confidence: confidence)
    }

    var facing: ShelfFacing?
    if let raw = obj["facing"] as? [String: Any],
       let categoryID = resolveCategory(string(raw["category_id"]), in: study.categories) {
      facing = ShelfFacing(categoryID: categoryID, confidence: clamp(number(raw["confidence"])))
    }

    let scene = SceneKind(rawValue: string(obj["scene"])?.lowercased() ?? "") ?? .other
    return Observation(held: held, facing: facing, scene: scene)
  }

  // MARK: Field coercion
  //
  // The model is asked for an id from the list, but it will occasionally return
  // the display name, a near-miss slug, or the string "null". Resolve against
  // the study and drop anything that does not land on something real -- an
  // unresolvable id must never reach a primitive.

  private static func resolveItem(_ raw: String?, in items: [WatchItem]) -> String? {
    guard let raw = usable(raw) else { return nil }
    if let match = Watchlist.item(withID: raw, in: items) { return match.id }
    return items.first { $0.displayName.caseInsensitiveCompare(raw) == .orderedSame }?.id
  }

  private static func resolveCategory(_ raw: String?, in categories: [WatchCategory]) -> String? {
    guard let raw = usable(raw) else { return nil }
    if let match = Watchlist.category(withID: raw, in: categories) { return match.id }
    return categories.first { $0.displayName.caseInsensitiveCompare(raw) == .orderedSame }?.id
  }

  private static func usable(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty,
          !["null", "none", "n/a"].contains(trimmed.lowercased())
    else { return nil }
    return trimmed
  }

  private static func string(_ value: Any?) -> String? {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty
    else { return nil }
    return s
  }

  private static func number(_ value: Any?) -> Double {
    (value as? Double) ?? (value as? NSNumber)?.doubleValue ?? 0
  }

  private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

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
