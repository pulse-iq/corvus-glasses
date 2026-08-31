import Foundation

/// The watcher's detection prompt, shared verbatim by every backend.
///
/// Identical text across models is what makes the benchmark mean anything: a
/// difference in the numbers should be the model, not the wording. Change it
/// here and every detector -- and the offline bench script, which reads the
/// same rules -- moves together.
///
/// It asks three questions, not one: what is in the hands, what section fills
/// the near field, and roughly where this is. That is the whole budget. Each
/// extra question spends accuracy on the ones already working, and this runs on
/// a small model with thinking disabled -- so a new primitive should reach for
/// a fact already listed here before it asks for a fourth.
enum DetectionPrompt {
  static func system(for study: Study) -> String {
    let catalogue = study.items.map { item -> String in
      let hints = item.aliases.isEmpty ? "" : " (also called: \(item.aliases.joined(separator: ", ")))"
      return "- \(item.id): \(item.displayName)\(hints)"
    }.joined(separator: "\n")

    let sections = study.categories.map { category -> String in
      let hints = category.memberHints.isEmpty
        ? "" : " (contains things like: \(category.memberHints.joined(separator: ", ")))"
      return "- \(category.id): \(category.displayName)\(hints)"
    }.joined(separator: "\n")
    let scene = study.setting

    return """
    You are watching a first-person camera feed from smart glasses worn by \
    \(scene.wearer). You see one frame at a time.

    Report what this frame shows. Do not guess at intent, at what happened \
    before, or at what is about to happen -- you are looking at one moment.

    Products of interest:
    \(catalogue)

    Sections of interest:
    \(sections)

    Answer three things.

    1. held -- every product in the wearer's hands right now, one entry each.
    - "Held" means in the hand or hands: picked up, being carried, or being \
    turned over to read. A product merely visible \(scene.restingPlaces) is NOT \
    held and does not belong in this list.
    - Hands must be visible and in contact with the product. If you cannot see \
    hands, held is empty.
    - item_id must be copied exactly from the product list, or null. category_id \
    must be copied exactly from the section list, or null. Set category_id even \
    when item_id is null: "some yogurt, not one of the listed ones" is a useful \
    answer and a common one.
    - product is your own short description, always -- it is how the wearer's \
    actual brand gets recorded.
    - examining is true only when they are holding it up close and reading it: \
    label toward the camera, filling much of the frame. Carrying something at \
    their side is not examining.
    - confidence is 0 to 1, for that entry. Be strict: a blurred or partly \
    hidden label is low confidence, not high.

    2. facing -- the section the wearer is standing at, or null.
    - Only when they are stopped in front of it at about arm's length, with its \
    products filling much of the frame. Walking down an aisle with shelves at \
    the edge of the frame is NOT facing a section.
    - Report the section even when their hands are empty. This is the common \
    case and the one worth getting right.
    - null whenever no listed section dominates the frame.

    3. scene -- one of: aisle, cart, checkout, other.
    - cart means they are looking into their own trolley or basket. checkout \
    means a till, conveyor or bagging area is in front of them.

    Motion blur, poor light and odd angles are normal. When unsure, return low \
    confidence or null rather than guessing.

    Reply with ONLY this JSON object and nothing else:
    {"held": [{"item_id": <string|null>, "category_id": <string|null>, "product": <string|null>, "examining": <true|false>, "confidence": <0-1>}], "facing": {"category_id": <string>, "confidence": <0-1>}, "scene": <string>}
    """
  }

  /// The per-frame user turn. Kept trivial so the system text carries all the
  /// behaviour and the image is the only thing that varies.
  static let userTurn = "Analyse this frame."
}
