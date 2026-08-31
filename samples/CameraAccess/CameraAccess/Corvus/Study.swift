import Foundation

/// One configured piece of fieldwork: who we are watching for, what we ask, and
/// how eagerly we interrupt.
///
/// This is the row shape. Today it loads from JSON on disk; when Corvus's
/// backend takes over, `Study` becomes a table and `StudyStore` becomes a fetch
/// — the rest of the watcher should not have to notice. Everything a run needs is
/// here rather than compiled in, because the watchlist changes per participant
/// and a rebuild per participant is not a workflow.
struct Study: Codable, Identifiable, Equatable {
  let id: String
  let name: String
  /// Free text for whoever reads the logs later. Never sent to a model.
  var notes: String?
  var items: [WatchItem]
  /// Shelf sections. A study can run on items alone, but a real shop cannot be
  /// enumerated, and the primitives about a choice rather than a product --
  /// standing in front of a range, holding two of them at once -- have nothing
  /// to aim at without these.
  var categories: [WatchCategory] = []
  /// Partial overrides; anything omitted keeps the default.
  var triggerPolicy: TriggerPolicy?
  /// Where this study happens. Omitted means a grocery store.
  var scene: StudyScene?
  /// What the researcher is trying to learn, in plain prose. Unlike `notes`
  /// this IS sent to the model -- it is what a conversational interceptor steers
  /// by, and the difference between a probing follow-up and a generic one.
  var researchGoal: String?

  var policy: TriggerPolicy { triggerPolicy ?? .default }
  var setting: StudyScene { scene ?? .groceryStore }

  enum CodingKeys: String, CodingKey {
    case id, name, notes, items, categories, triggerPolicy, scene, researchGoal
  }

  init(
    id: String, name: String, notes: String? = nil, items: [WatchItem],
    categories: [WatchCategory] = [], triggerPolicy: TriggerPolicy? = nil,
    scene: StudyScene? = nil, researchGoal: String? = nil
  ) {
    self.id = id
    self.name = name
    self.notes = notes
    self.items = items
    self.categories = categories
    self.triggerPolicy = triggerPolicy
    self.scene = scene
    self.researchGoal = researchGoal
  }

  // Hand-written because a synthesised decoder ignores a property's default and
  // demands the key anyway -- which would have made every study file written
  // before sections existed stop loading the day they were added.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    notes = try c.decodeIfPresent(String.self, forKey: .notes)
    items = try c.decodeIfPresent([WatchItem].self, forKey: .items) ?? []
    categories = try c.decodeIfPresent([WatchCategory].self, forKey: .categories) ?? []
    triggerPolicy = try c.decodeIfPresent(TriggerPolicy.self, forKey: .triggerPolicy)
    scene = try c.decodeIfPresent(StudyScene.self, forKey: .scene)
    researchGoal = try c.decodeIfPresent(String.self, forKey: .researchGoal)
  }
}

/// Where the wearer is, in the model's words.
///
/// The detector's hardest call is "held versus merely present", and the answer
/// depends entirely on the room: a jar on a shop shelf and a jar on a kitchen
/// counter are the same pixels and opposite verdicts. Telling the model it is
/// in a supermarket while it looks at a fridge spends accuracy for nothing, so
/// the scene travels with the study rather than being frozen into the prompt.
struct StudyScene: Codable, Equatable {
  /// Completes "worn by ...".
  var wearer: String
  /// Completes "A product merely visible ... is NOT held."
  var restingPlaces: String

  static let groceryStore = StudyScene(
    wearer: "a shopper in a grocery store",
    restingPlaces: "on a shelf, in a cart, or in a basket")

  static let kitchen = StudyScene(
    wearer: "someone moving around their own kitchen",
    restingPlaces: "on a counter, in a fridge, in a cupboard, or in the sink")
}

/// Finds studies and remembers which one is running.
///
/// Two sources, user files first: bundled JSON ships with the app, and anything
/// dropped into `Documents/corvus/studies/` overrides it by id. That second path
/// is what lets a study be revised on a phone in a car park without Xcode.
@MainActor
final class StudyStore: ObservableObject {
  static let shared = StudyStore()

  @Published private(set) var studies: [Study] = []
  @Published private(set) var active: Study
  /// Files that would not decode, with the reason. Surfaced rather than only
  /// logged: a study that silently failed to load looks exactly like a watcher
  /// that is not firing.
  @Published private(set) var loadErrors: [String] = []

  /// Preferred on a fresh install, before anyone has picked one.
  static let defaultStudyID = "grocery-pilot"

  /// Last-resort study, used only when no JSON can be read at all. Keeps the
  /// watcher runnable rather than dead on a packaging mistake.
  static let fallback = Study(
    id: "fallback",
    name: "Fallback (no study file found)",
    notes: "Bundled JSON failed to load. Check Corvus/Studies/.",
    items: [],
    triggerPolicy: nil)

  private init() {
    active = Self.fallback
    reload()
  }

  var userStudiesDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("corvus/studies", isDirectory: true)
  }

  func reload() {
    var byID: [String: Study] = [:]
    var errors: [String] = []
    let decoder = JSONDecoder()

    func load(_ url: URL, origin: String) {
      do {
        let study = try decoder.decode(Study.self, from: Data(contentsOf: url))
        byID[study.id] = study
      } catch {
        // The reason, not just the fact. A study whose policy key was renamed
        // and a study with a stray comma fail identically from the outside, and
        // they call for opposite fixes.
        let reason = Self.describe(error)
        errors.append("\(origin) \(url.lastPathComponent): \(reason)")
        NSLog("[Corvus] could not decode %@ study %@: %@", origin, url.lastPathComponent, reason)
      }
    }

    for url in Self.bundledStudyURLs() {
      load(url, origin: "bundled")
    }
    // User files win: a revision dropped on the device should beat the copy
    // baked in at build time.
    let userFiles = (try? FileManager.default.contentsOfDirectory(
      at: userStudiesDirectory, includingPropertiesForKeys: nil)) ?? []
    for url in userFiles where url.pathExtension.lowercased() == "json" {
      load(url, origin: "user")
    }

    studies = byID.values.sorted { $0.name < $1.name }
    loadErrors = errors
    let remembered = UserDefaults.standard.string(forKey: "corvus.activeStudyID")
    // Alphabetical order is for the picker, not for choosing a default. The
    // shop study is the one being run now, so it wins a fresh install; the
    // kitchen study stays as the bench, selected by hand.
    active = studies.first { $0.id == remembered }
      ?? studies.first { $0.id == Self.defaultStudyID }
      ?? studies.first
      ?? Self.fallback
  }

  func activate(_ study: Study) {
    active = study
    UserDefaults.standard.set(study.id, forKey: "corvus.activeStudyID")
  }

  private static func describe(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else { return error.localizedDescription }
    switch decoding {
    case .dataCorrupted(let ctx), .keyNotFound(_, let ctx),
         .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
      let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
      return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
    @unknown default:
      return decoding.localizedDescription
    }
  }

  private static func bundledStudyURLs() -> [URL] {
    // Synchronized folder groups flatten resources into the bundle root, but a
    // Studies/ subdirectory survives some build settings -- look in both rather
    // than depend on which.
    var urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Studies") ?? []
    urls += (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
    // Only files that actually decode as a Study; the bundle holds other JSON.
    return urls
  }
}

// MARK: - Policy decoding

/// A key by any name, so a container's actual keys can be inspected rather than
/// only the ones we thought to ask for.
private struct AnyKey: CodingKey {
  let stringValue: String
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.init(stringValue) }
  var intValue: Int? { nil }
  init?(intValue: Int) { nil }
}

/// Every field optional, so a study can override one threshold without
/// restating the whole policy.
///
/// **Unknown keys are a decoding error, not a shrug.** The tempting shape is to
/// ignore anything unrecognised, and it is a trap: rename a field and every
/// study file that overrode it goes on parsing cleanly while the override stops
/// applying, so the watcher runs on defaults and nothing anywhere says so. A
/// study that fails to load is loud. A study that silently ignores half its
/// tuning is not.
extension TriggerPolicy: Codable {
  /// The pre-primitive shape, kept working because both study files on disk use
  /// it and a rename that silently drops tuning is exactly what this file is
  /// trying to prevent. These map onto `holding`, which is what they meant.
  private static let legacyKeys: Set<String> = [
    "minConfidence", "consecutiveHits", "streakWindow", "perItemCooldown",
  ]
  private static let ownKeys: Set<String> = [
    "primitives", "globalCooldown", "maxInterceptDuration", "maxInterceptsPerTrip",
  ]

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: AnyKey.self)
    let present = Set(c.allKeys.map(\.stringValue))
    let known = Self.ownKeys.union(Self.legacyKeys)
    if let stray = present.subtracting(known).sorted().first {
      throw DecodingError.dataCorruptedError(
        forKey: AnyKey(stray), in: c,
        debugDescription: "unknown trigger policy key \"\(stray)\"; expected one of "
          + known.sorted().joined(separator: ", "))
    }

    var policy = TriggerPolicy()
    if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("globalCooldown")) {
      policy.globalCooldown = v
    }
    if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("maxInterceptDuration")) {
      policy.maxInterceptDuration = v
    }
    if let v = try c.decodeIfPresent(Int.self, forKey: AnyKey("maxInterceptsPerTrip")) {
      policy.maxInterceptsPerTrip = v
    }

    // Legacy first, so an explicit `primitives.holding` block wins over the flat
    // keys if a file is halfway through being migrated.
    if !present.isDisjoint(with: Self.legacyKeys) {
      var holding = PrimitivePolicy.default(for: .holding)
      if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("minConfidence")) {
        holding.minConfidence = v
      }
      if let v = try c.decodeIfPresent(Int.self, forKey: AnyKey("consecutiveHits")) {
        holding.consecutiveHits = v
      }
      if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("streakWindow")) {
        holding.streakWindow = v
      }
      if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("perItemCooldown")) {
        holding.cooldown = v
      }
      policy.primitives[.holding] = holding
    }

    if c.contains(AnyKey("primitives")) {
      let nested = try c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("primitives"))
      for key in nested.allKeys {
        guard let kind = PrimitiveKind(rawValue: key.stringValue) else {
          throw DecodingError.dataCorruptedError(
            forKey: key, in: nested,
            debugDescription: "unknown primitive \"\(key.stringValue)\"; expected one of "
              + PrimitiveKind.allCases.map(\.rawValue).sorted().joined(separator: ", "))
        }
        let body = try nested.nestedContainer(keyedBy: AnyKey.self, forKey: key)
        policy.primitives[kind] = try PrimitivePolicy(from: body, kind: kind)
      }
    }

    self = policy
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: AnyKey.self)
    try c.encode(globalCooldown, forKey: AnyKey("globalCooldown"))
    try c.encode(maxInterceptDuration, forKey: AnyKey("maxInterceptDuration"))
    try c.encode(maxInterceptsPerTrip, forKey: AnyKey("maxInterceptsPerTrip"))
    guard !primitives.isEmpty else { return }
    var nested = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("primitives"))
    for (kind, p) in primitives.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      var body = nested.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(kind.rawValue))
      try p.encode(to: &body)
    }
  }
}

extension PrimitivePolicy {
  fileprivate static let keys: Set<String> = [
    "enabled", "minConfidence", "consecutiveHits", "streakWindow", "cooldown",
  ]

  /// Starts from the kind's own defaults, so a study overriding one threshold
  /// does not have to restate the other four.
  fileprivate init(from c: KeyedDecodingContainer<AnyKey>, kind: PrimitiveKind) throws {
    let present = Set(c.allKeys.map(\.stringValue))
    if let stray = present.subtracting(Self.keys).sorted().first {
      throw DecodingError.dataCorruptedError(
        forKey: AnyKey(stray), in: c,
        debugDescription: "unknown key \"\(stray)\" for primitive \(kind.rawValue); "
          + "expected one of " + Self.keys.sorted().joined(separator: ", "))
    }
    var p = PrimitivePolicy.default(for: kind)
    if let v = try c.decodeIfPresent(Bool.self, forKey: AnyKey("enabled")) { p.enabled = v }
    if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("minConfidence")) {
      p.minConfidence = v
    }
    if let v = try c.decodeIfPresent(Int.self, forKey: AnyKey("consecutiveHits")) {
      p.consecutiveHits = v
    }
    if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("streakWindow")) {
      p.streakWindow = v
    }
    if let v = try c.decodeIfPresent(Double.self, forKey: AnyKey("cooldown")) { p.cooldown = v }
    self = p
  }

  fileprivate func encode(to c: inout KeyedEncodingContainer<AnyKey>) throws {
    try c.encode(enabled, forKey: AnyKey("enabled"))
    try c.encode(minConfidence, forKey: AnyKey("minConfidence"))
    try c.encode(consecutiveHits, forKey: AnyKey("consecutiveHits"))
    try c.encode(streakWindow, forKey: AnyKey("streakWindow"))
    try c.encode(cooldown, forKey: AnyKey("cooldown"))
  }
}
