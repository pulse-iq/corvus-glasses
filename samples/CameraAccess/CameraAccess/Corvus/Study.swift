import Foundation

/// One configured piece of fieldwork: who we are watching for, what we ask, and
/// how eagerly we interrupt.
///
/// This is the row shape. Today it loads from JSON on disk; when Corvus's
/// backend takes over, `Study` becomes a table and `StudyStore` becomes a fetch
/// — the rest of Stage 1 should not have to notice. Everything a run needs is
/// here rather than compiled in, because the watchlist changes per participant
/// and a rebuild per participant is not a workflow.
struct Study: Codable, Identifiable, Equatable {
  let id: String
  let name: String
  /// Free text for whoever reads the logs later. Never sent to a model.
  var notes: String?
  var items: [WatchItem]
  /// Partial overrides; anything omitted keeps the default.
  var triggerPolicy: TriggerPolicy?
  /// Where this study happens. Omitted means a grocery store.
  var scene: StudyScene?

  var policy: TriggerPolicy { triggerPolicy ?? .default }
  var setting: StudyScene { scene ?? .groceryStore }
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
  /// Completes "A product merely visible ... is NOT being held."
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

  /// Preferred on a fresh install, before anyone has picked one.
  static let defaultStudyID = "kitchen-dev"

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
    let decoder = JSONDecoder()

    for url in Self.bundledStudyURLs() {
      if let study = try? decoder.decode(Study.self, from: Data(contentsOf: url)) {
        byID[study.id] = study
      } else {
        NSLog("[Corvus] could not decode bundled study: %@", url.lastPathComponent)
      }
    }
    // User files win: a revision dropped on the device should beat the copy
    // baked in at build time.
    let userFiles = (try? FileManager.default.contentsOfDirectory(
      at: userStudiesDirectory, includingPropertiesForKeys: nil)) ?? []
    for url in userFiles where url.pathExtension.lowercased() == "json" {
      if let study = try? decoder.decode(Study.self, from: Data(contentsOf: url)) {
        byID[study.id] = study
      } else {
        NSLog("[Corvus] could not decode user study: %@", url.lastPathComponent)
      }
    }

    studies = byID.values.sorted { $0.name < $1.name }
    let remembered = UserDefaults.standard.string(forKey: "corvus.activeStudyID")
    // Alphabetical order is for the picker, not for choosing a default. Until
    // fieldwork actually moves to a shop, the kitchen study is the one being
    // run, so it wins a fresh install.
    active = studies.first { $0.id == remembered }
      ?? studies.first { $0.id == Self.defaultStudyID }
      ?? studies.first
      ?? Self.fallback
  }

  func activate(_ study: Study) {
    active = study
    UserDefaults.standard.set(study.id, forKey: "corvus.activeStudyID")
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

// MARK: - Partial decoding

/// Every field optional in JSON, so a study can override one threshold without
/// restating the whole policy — and adding a field here never invalidates an
/// existing study file.
extension TriggerPolicy: Codable {
  enum CodingKeys: String, CodingKey {
    case minConfidence, consecutiveHits, streakWindow
    case perItemCooldown, globalCooldown, maxInterviewDuration
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    var p = TriggerPolicy.default
    if let v = try c.decodeIfPresent(Double.self, forKey: .minConfidence) { p.minConfidence = v }
    if let v = try c.decodeIfPresent(Int.self, forKey: .consecutiveHits) { p.consecutiveHits = v }
    if let v = try c.decodeIfPresent(Double.self, forKey: .streakWindow) { p.streakWindow = v }
    if let v = try c.decodeIfPresent(Double.self, forKey: .perItemCooldown) { p.perItemCooldown = v }
    if let v = try c.decodeIfPresent(Double.self, forKey: .globalCooldown) { p.globalCooldown = v }
    if let v = try c.decodeIfPresent(Double.self, forKey: .maxInterviewDuration) {
      p.maxInterviewDuration = v
    }
    self = p
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(minConfidence, forKey: .minConfidence)
    try c.encode(consecutiveHits, forKey: .consecutiveHits)
    try c.encode(streakWindow, forKey: .streakWindow)
    try c.encode(perItemCooldown, forKey: .perItemCooldown)
    try c.encode(globalCooldown, forKey: .globalCooldown)
    try c.encode(maxInterviewDuration, forKey: .maxInterviewDuration)
  }
}
