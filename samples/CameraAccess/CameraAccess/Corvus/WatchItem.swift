import Foundation

/// Opening questions, keyed by the primitive that earned the intercept.
///
/// Picking a bottle up and standing in front of the whole shelf are different
/// moments and deserve different first lines; asking "what are you looking at
/// on the label there?" of someone who has not touched anything is the kind of
/// wrongness a participant notices immediately. `fallback` is what any
/// primitive without its own wording gets, so a study that does not care about
/// the distinction stays a single string in JSON.
struct QuestionSet: Codable, Equatable, Hashable {
  var fallback: String
  var byPrimitive: [String: String] = [:]

  init(_ fallback: String, byPrimitive: [String: String] = [:]) {
    self.fallback = fallback
    self.byPrimitive = byPrimitive
  }

  func question(for kind: PrimitiveKind) -> String {
    byPrimitive[kind.rawValue] ?? fallback
  }

  /// Decodes from either `"question": "..."` or
  /// `"question": {"default": "...", "dwell": "..."}`. The string form is not a
  /// legacy shape to be migrated away from -- it is the right shape for most
  /// items, and every study file on disk uses it.
  init(from decoder: Decoder) throws {
    let single = try decoder.singleValueContainer()
    if let text = try? single.decode(String.self) {
      self.init(text)
      return
    }
    var map = try single.decode([String: String].self)
    guard let fallback = map.removeValue(forKey: "default") else {
      throw DecodingError.dataCorruptedError(
        in: single,
        debugDescription: "a question object needs a \"default\"; got keys: "
          + map.keys.sorted().joined(separator: ", "))
    }
    let known = Set(PrimitiveKind.allCases.map(\.rawValue))
    if let stray = map.keys.first(where: { !known.contains($0) }) {
      // Loudly, because the alternative is a per-primitive question that is
      // simply never asked and never complained about.
      throw DecodingError.dataCorruptedError(
        in: single,
        debugDescription: "\"\(stray)\" is not a primitive; expected one of "
          + known.sorted().joined(separator: ", "))
    }
    self.init(fallback, byPrimitive: map)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    if byPrimitive.isEmpty {
      try c.encode(fallback)
    } else {
      var map = byPrimitive
      map["default"] = fallback
      try c.encode(map)
    }
  }
}

/// Which primitives an entry actually runs, when it says.
///
/// Absent means every primitive the target can support, which is the right
/// default for a study that has not thought about it. Naming them is how a
/// pilot stays legible: forty primitives across fourteen entries is a lot of
/// ways to be interrupted, and most of a first field trip is learning whether
/// one or two of them fire at the right moment.
enum PrimitiveSet {
  /// Validated against what the target can support, so `dwell` on a single
  /// product is a study that fails to load rather than a line that quietly
  /// does nothing -- you cannot stand in front of one jar.
  static func parse(_ raw: [String], isItem: Bool) throws -> [PrimitiveKind] {
    let allowed = PrimitiveKind.applicable(toItem: isItem)
    var kinds: [PrimitiveKind] = []
    for name in raw {
      guard let kind = PrimitiveKind(rawValue: name) else {
        throw StudyConfigError.unknownPrimitive(name)
      }
      guard allowed.contains(kind) else {
        throw StudyConfigError.wrongTarget(name, isItem: isItem)
      }
      if !kinds.contains(kind) { kinds.append(kind) }
    }
    return kinds
  }
}

enum StudyConfigError: Error, LocalizedError {
  case unknownPrimitive(String)
  case wrongTarget(String, isItem: Bool)

  var errorDescription: String? {
    switch self {
    case .unknownPrimitive(let name):
      return "unknown primitive \"\(name)\"; expected one of "
        + PrimitiveKind.allCases.map(\.rawValue).sorted().joined(separator: ", ")
    case .wrongTarget(let name, let isItem):
      return isItem
        ? "\"\(name)\" cannot target a single product; it needs a section"
        : "\"\(name)\" cannot target a section"
    }
  }
}

/// One product the study is watching for. `id` is what the detector must return
/// -- a short, unambiguous token the model can copy verbatim -- while
/// `displayName` and `aliases` exist to help the model recognise the thing on a
/// shelf, where the shopper sees a brand, not our slug.
struct WatchItem: Identifiable, Codable, Equatable, Hashable {
  let id: String
  let displayName: String
  /// Other names the product goes by on packaging or in speech. Fed to the
  /// model as recognition hints; never returned.
  let aliases: [String]
  /// The opening intercept question. The interceptor seeds the voice session
  /// with it; the watcher carries it so the trigger is whole.
  let questions: QuestionSet
  /// Asked in order after the opening question, each with its own recording.
  /// Empty is the normal case -- an intercept earns a few seconds of someone's
  /// attention, not an interview.
  let followUps: [String]
  /// Which shelf section this belongs to, if the study defines one. What lets
  /// a dwell on `bread` and a pickup of `sourdough` agree about what happened.
  let categoryID: String?
  /// Narrows what this item watches for. Empty means everything an item can do.
  let primitives: [PrimitiveKind]

  init(
    id: String, displayName: String, aliases: [String] = [], question: String,
    followUps: [String] = [], categoryID: String? = nil,
    primitives: [PrimitiveKind] = []
  ) {
    self.init(
      id: id, displayName: displayName, aliases: aliases,
      questions: QuestionSet(question), followUps: followUps, categoryID: categoryID,
      primitives: primitives)
  }

  init(
    id: String, displayName: String, aliases: [String] = [], questions: QuestionSet,
    followUps: [String] = [], categoryID: String? = nil,
    primitives: [PrimitiveKind] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.aliases = aliases
    self.questions = questions
    self.followUps = followUps
    self.categoryID = categoryID
    self.primitives = primitives
  }

  // Hand-written so that adding a field never invalidates a study file already
  // sitting on someone's phone -- the same reason TriggerPolicy decodes this way.
  enum CodingKeys: String, CodingKey {
    case id, displayName, aliases, question, followUps, categoryID, primitives
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    displayName = try c.decode(String.self, forKey: .displayName)
    aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    questions = try c.decode(QuestionSet.self, forKey: .question)
    followUps = try c.decodeIfPresent([String].self, forKey: .followUps) ?? []
    categoryID = try c.decodeIfPresent(String.self, forKey: .categoryID)
    primitives = try PrimitiveSet.parse(
      c.decodeIfPresent([String].self, forKey: .primitives) ?? [], isItem: true)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(displayName, forKey: .displayName)
    if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
    try c.encode(questions, forKey: .question)
    if !followUps.isEmpty { try c.encode(followUps, forKey: .followUps) }
    try c.encodeIfPresent(categoryID, forKey: .categoryID)
    if !primitives.isEmpty { try c.encode(primitives.map(\.rawValue), forKey: .primitives) }
  }
}

/// A shelf section: bread, plant milks, breakfast cereal.
///
/// A category exists because a real shop cannot be enumerated. A study can name
/// every yogurt it cares about and still miss the one someone picks up, whereas
/// "the yogurt section" covers the aisle. It is also the only sensible target
/// for the primitives that are about a choice rather than a product -- standing
/// in front of a range, or holding two of them at once.
struct WatchCategory: Identifiable, Codable, Equatable, Hashable {
  let id: String
  let displayName: String
  /// Example members, so the model can recognise the section from its contents
  /// rather than from signage it may not be able to read.
  let memberHints: [String]
  let questions: QuestionSet
  /// Narrows what this section watches for. Empty means everything.
  let primitives: [PrimitiveKind]

  init(
    id: String, displayName: String, memberHints: [String] = [], question: String,
    primitives: [PrimitiveKind] = []
  ) {
    self.init(
      id: id, displayName: displayName, memberHints: memberHints,
      questions: QuestionSet(question), primitives: primitives)
  }

  init(
    id: String, displayName: String, memberHints: [String] = [], questions: QuestionSet,
    primitives: [PrimitiveKind] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.memberHints = memberHints
    self.questions = questions
    self.primitives = primitives
  }

  enum CodingKeys: String, CodingKey {
    case id, displayName, memberHints, question, primitives
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    displayName = try c.decode(String.self, forKey: .displayName)
    memberHints = try c.decodeIfPresent([String].self, forKey: .memberHints) ?? []
    questions = try c.decode(QuestionSet.self, forKey: .question)
    primitives = try PrimitiveSet.parse(
      c.decodeIfPresent([String].self, forKey: .primitives) ?? [], isItem: false)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(displayName, forKey: .displayName)
    if !memberHints.isEmpty { try c.encode(memberHints, forKey: .memberHints) }
    try c.encode(questions, forKey: .question)
    if !primitives.isEmpty { try c.encode(primitives.map(\.rawValue), forKey: .primitives) }
  }
}

/// What a primitive is pointed at.
///
/// This is the parameterisation the whole design turns on: `holding` and
/// `dwell` differ in their predicate, not in what they can be aimed at, so a
/// primitive takes a target and every primitive works against items and
/// sections alike.
enum WatchTarget: Equatable, Hashable {
  case item(String)
  case category(String)

  /// Stable key for cooldowns and log lines. Prefixed because an item and a
  /// section are allowed to share a slug.
  var id: String {
    switch self {
    case .item(let id): return "item:\(id)"
    case .category(let id): return "category:\(id)"
    }
  }

  var rawID: String {
    switch self {
    case .item(let id), .category(let id): return id
    }
  }

  /// Ties are broken towards the more specific target: if a study watches both
  /// `sourdough` and the `bread` section, picking up a sourdough loaf is a fact
  /// about the loaf.
  var specificity: Int {
    switch self {
    case .item: return 1
    case .category: return 0
    }
  }
}

/// The resolved thing an intercept is about: what to call it, what to open
/// with, and what just happened.
///
/// Interceptors take this rather than a `WatchItem` because a trigger no longer
/// always concerns one product. Everything downstream of the watcher asks the
/// same four questions of it regardless of which primitive fired.
struct InterceptSubject: Equatable, Codable {
  let targetID: String
  let displayName: String
  /// A whole sentence about the wearer, starting with "They". Written by the
  /// primitive that fired, because "They have just picked up the olive oil" and
  /// "They have been standing in front of the bread" occupy the same slot in
  /// the intercept prompt and describe completely different moments.
  let situation: String
  let question: String
  let followUps: [String]
}

/// Watchlist lookup. The lists themselves live in a `Study`, loaded from JSON
/// -- see `Study.swift`. They change per participant, and a rebuild per
/// participant is not a workflow.
enum Watchlist {
  static func item(withID id: String, in items: [WatchItem]) -> WatchItem? {
    items.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
  }

  static func category(withID id: String, in categories: [WatchCategory]) -> WatchCategory? {
    categories.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
  }
}
