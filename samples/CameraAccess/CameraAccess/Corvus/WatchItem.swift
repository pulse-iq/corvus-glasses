import Foundation

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
  /// The opening interview question for this item. Stage 2 seeds the voice
  /// session with it; Stage 1 only carries it so the trigger arrives complete.
  let question: String

  init(id: String, displayName: String, aliases: [String] = [], question: String) {
    self.id = id
    self.displayName = displayName
    self.aliases = aliases
    self.question = question
  }
}

/// Watchlist lookup. The list itself lives in a `Study`, loaded from JSON --
/// see `Study.swift`. It changes per participant, and a rebuild per participant
/// is not a workflow.
enum Watchlist {
  static func item(withID id: String, in items: [WatchItem]) -> WatchItem? {
    items.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
  }
}
