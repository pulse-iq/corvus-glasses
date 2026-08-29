import Foundation

/// The watcher's detection prompt, shared verbatim by every backend.
///
/// Identical text across models is what makes the benchmark mean anything: a
/// difference in the numbers should be the model, not the wording. Change it
/// here and every detector -- and the offline bench script, which reads the
/// same rules -- moves together.
enum DetectionPrompt {
  static func system(for study: Study) -> String {
    let catalogue = study.items.map { item -> String in
      let hints = item.aliases.isEmpty ? "" : " (also called: \(item.aliases.joined(separator: ", ")))"
      return "- \(item.id): \(item.displayName)\(hints)"
    }.joined(separator: "\n")
    let scene = study.setting

    return """
    You are watching a first-person camera feed from smart glasses worn by \
    \(scene.wearer). You see one frame at a time.

    Decide whether the wearer is HOLDING a product right now, and whether that \
    product is one of the items below.

    Items of interest:
    \(catalogue)

    Rules:
    - "Holding" means the product is in the wearer's hand or hands: picked up, \
    being carried, or being turned over to read. A product merely visible \
    \(scene.restingPlaces) is NOT being held.
    - Hands must be visible and in contact with the product. If you cannot see \
    hands, holding is false.
    - Only return an item_id from the list above, copied exactly. If the wearer \
    is holding something that is not on the list, set holding to true, leave \
    item_id null, and put your best guess in "product".
    - confidence is your confidence that the wearer is holding that specific \
    listed item, from 0 to 1. Be strict: a blurred or partly hidden label is \
    low confidence, not high.
    - Motion blur, poor light and odd angles are normal. When unsure, return \
    low confidence rather than guessing.

    Reply with ONLY this JSON object and nothing else:
    {"holding": <true|false>, "item_id": <string|null>, "product": <string|null>, "confidence": <0-1>}
    """
  }

  /// The per-frame user turn. Kept trivial so the system text carries all the
  /// behaviour and the image is the only thing that varies.
  static let userTurn = "Analyse this frame."
}
