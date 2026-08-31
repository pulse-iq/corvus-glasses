# Studies

A **study** is one configured piece of fieldwork: who we are watching for, what
we ask them, and how eagerly we interrupt. It is a JSON file, not code, because
the watchlist changes per participant and a rebuild per participant is not a
workflow.

## Where studies come from

Two sources, merged by `id`, **user files win**:

1. `Corvus/Studies/*.json` — bundled into the app at build time
2. `Documents/corvus/studies/*.json` — dropped onto the device afterwards

That second path is the point: a study can be revised on a phone in a car park
without Xcode. Push a file into the app's Documents container and relaunch.

The app selects `grocery-pilot` on a fresh install, remembers whatever you pick
after that, and shows the picker under Settings → Corvus.

A file that fails to decode is surfaced in the UI with its reason, not just
logged. A study that silently failed to load looks exactly like a watcher that
is not firing, and the two need opposite fixes.

## A complete study

```jsonc
{
  "id": "grocery-pilot",
  "name": "Grocery pilot",
  "notes": "Free text for whoever reads the logs. Never sent to a model.",

  // Sent to the model. What the interceptor steers by, and the difference
  // between a probing follow-up and a generic one.
  "researchGoal": "Understand what drives shelf-level decisions in store...",

  // Where this study happens. Omitted means a grocery store.
  "scene": {
    "wearer": "a shopper in a grocery store",
    "restingPlaces": "on a shelf, in a cart, or in a basket"
  },

  "items": [
    {
      "id": "olive_oil",                    // what the detector must return
      "displayName": "olive oil",
      "aliases": ["extra virgin olive oil", "EVOO", "bottle of cooking oil"],
      "question": "What made you reach for that one?",
      "categoryID": "cooking_oils",         // optional; ties into a section
      "primitives": ["holding"],            // omit for everything applicable
      "followUps": []                       // asked in order, each recorded
    }
  ],

  "categories": [
    {
      "id": "cooking_oils",
      "displayName": "cooking oils",
      "memberHints": ["olive oil", "avocado oil", "vegetable oil"],
      "question": {
        "default": "What made you go for that one?",
        "dwell":    "What are you after in an oil today?"
      },
      "primitives": ["dwell", "holding"]
    }
  ],

  "triggerPolicy": { /* see below; every field optional */ }
}
```

### `scene` matters more than it looks

The detector's hardest call is **held versus merely present**, and the answer
depends entirely on the room. A jar on a shop shelf and a jar on a kitchen
counter are the same pixels and opposite verdicts. Telling the model it is in a
supermarket while it looks at a fridge spends accuracy for nothing.

`wearer` completes "worn by …". `restingPlaces` completes "A product merely
visible … is NOT held."

### Items vs. categories

An **item** is one product. A **category** is a shelf section.

Categories exist because a real shop cannot be enumerated: a study can name every
yogurt it cares about and still miss the one someone picks up, whereas "the
yogurt section" covers the aisle. They are also the only sensible target for the
primitives that are about a *choice* rather than a *product* — `comparing` and
`dwell` require a category and are rejected on an item.

`memberHints` lets the model recognise a section from its contents rather than
from signage it may not be able to read.

When both could fire, the more specific target wins: if a study watches both
`sourdough` and the `bread` section, picking up a sourdough loaf is a fact about
the loaf.

### Questions

`question` takes either a string or an object keyed by primitive:

```jsonc
"question": "What made you reach for that one?"

"question": {
  "default": "What made you go for that one?",
  "dwell":   "What are you after in an oil today?"
}
```

The string form is not a legacy shape to migrate away from — it is the right
shape for most entries. Use the object form when the moment changes the opening
line: asking "what are you looking at on the label there?" of someone who has
not touched anything is the kind of wrongness a participant notices immediately.

An object needs a `"default"`. Any other key must be a real primitive name.

`followUps` are asked in order after the opener, each with its own recording.
Empty is the normal case — an intercept earns a few seconds of someone's
attention, not an interview.

## Trigger policy

Every field is optional and overrides one default; anything omitted keeps its
own default rather than a shared one, because a dwell and a pickup are not the
same bet.

```jsonc
"triggerPolicy": {
  "globalCooldown": 90,          // quiet period after any intercept ends
  "maxInterceptDuration": 120,   // safety valve if an intercept never reports back
  "maxInterceptsPerTrip": 12,    // hard ceiling per run of the watcher

  "primitives": {
    "holding": {
      "enabled": true,
      "minConfidence": 0.6,      // below this, the frame does not count at all
      "consecutiveHits": 2,      // evidence needed to fire
      "streakWindow": 6,         // seconds those hits must fall within
      "cooldown": 600            // before this target may fire this primitive again
    }
  }
}
```

Per-primitive defaults:

| Primitive | `minConfidence` | `consecutiveHits` | `streakWindow` | `cooldown` |
|---|---|---|---|---|
| `holding` | 0.6 | 2 | 6s | 600s |
| `examining` | 0.6 | 2 | 6s | 300s |
| `comparing` | 0.5 | 2 | 6s | 300s |
| `dwell` | 0.5 | 5 | 12s | 900s |

`dwell` demands much more evidence because standing still is far weaker evidence
than picking something up, and far more frequent: a trip has tens of pickups and
hundreds of dwell-seconds. `comparing` sits at a lower floor on purpose — two
watched products in two hands is a strong structural signal even when neither
label reads cleanly.

**`streakWindow` must exceed `consecutiveHits` × detector round-trip**, or the
streak can never complete and the primitive will never fire. See
[architecture.md](architecture.md#tuning).

## Unknown keys are errors, on purpose

A misspelled or renamed key **fails the study loudly** rather than being ignored.
This applies to trigger policy keys, primitive names, primitive policy fields,
and per-primitive question keys.

The tempting shape is to shrug at anything unrecognised, and it is a trap:
rename a field and every study that overrode it goes on parsing cleanly while
the override stops applying, so the watcher runs on defaults and nothing
anywhere says so. A study that fails to load is loud; a study that silently
ignores half its tuning is not.

The one accommodation is the pre-primitive flat shape — `minConfidence`,
`consecutiveHits`, `streakWindow`, `perItemCooldown` at the top level — which
still parses and maps onto `holding`. An explicit `primitives.holding` block
wins over it.

## A note on the shipped study

`grocery-pilot` ships with demo tuning, not field tuning: a 5-second global
cooldown, 20-second per-target cooldowns, and a 500-intercept ceiling. That is
deliberate for showing the system working, and far too eager for real fieldwork
— it will interrupt someone repeatedly about the same product. Set the values
back toward the defaults above before a real trip.

Its `researchGoal` and questions are also placeholders. Replace them with the
actual study design before collecting anything you intend to use.
