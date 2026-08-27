# Corvus Stage 1 — the Watcher

Stage 1 watches the first-person camera feed and decides *when* to interview.
It ends at a `Trigger`; Stage 2 (the voice interviewer) does not exist yet.

## Pipeline

```
glasses (DAT)  ─┐
                ├─► FrameSampler ──► ProductDetector ──► TriggerStateMachine ──► Trigger
iPhone camera  ─┘   ~1 fps, 768px      one HTTP call       streak + cooldowns        │
                    JPEG q0.7          strict JSON                                   ▼
                                                                              CorvusLog (JSONL)
```

| File | Role |
|---|---|
| `WatchItem.swift` | The items of interest and their opening questions. **Placeholder data.** |
| `DetectionPrompt.swift` | The one prompt every backend sends. Source of truth, also read by the bench script. |
| `ProductDetector.swift` | Backend protocol, `Detection`, and the tolerant JSON parser. |
| `Detectors/*.swift` | Gemini, OpenAI, Anthropic clients. One HTTP call each. |
| `FrameSampler.swift` | Throttle, downscale, JPEG-encode. |
| `TriggerStateMachine.swift` | Streak, confidence, per-item and global cooldowns. Pure and clock-injected. |
| `WatcherCoordinator.swift` | Wires it together; publishes state for the bench UI. |
| `PhoneCameraSource.swift` | iPhone back camera, so Stage 1 runs with no glasses. |
| `CorvusWatcherView.swift` | The bench screen: Settings → Corvus → Watcher. |

## Frame sources

Both sources feed `WatcherCoordinator.submit(...)`.

- **Glasses**: `StreamSessionViewModel.onAnalysisFrame` — added for Corvus, fires
  on the foreground *and* background paths. This is deliberately separate from
  upstream's `onDecodedFrame`, which feeds the LiveKit publisher and fires only
  when the app is backgrounded.
- **iPhone**: `PhoneCameraSource`, owned by the bench screen.

## Keys

The app reads them from `Secrets.swift` (gitignored; copy `Secrets.swift.example`),
overridable at runtime from `UserDefaults` under `corvus.*`.

| Key | Needed for |
|---|---|
| `geminiAPIKey` | The default detector. Required. |
| `corvusOpenAIAPIKey` | Benchmarking the OpenAI backend only. |
| `corvusAnthropicAPIKey` | Benchmarking the Claude backend only. |

The offline bench script reads environment variables instead — an app bundle
has no environment, a script does. Copy `corvus-tools/.env.example` to
`corvus-tools/.env` and fill in `GEMINI_API_KEY`, `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`. An exported shell variable overrides the file, so a one-off
`GEMINI_API_KEY=... python3 corvus-tools/detector-bench.py ...` works too.

Both `Secrets.swift` and `.env` are gitignored. They hold the same keys in two
places because the app and the script have no way to share one.

## Benchmarking against saved frames

1. Settings → Corvus → Watcher → **Save frames for benchmarking**, then walk a trip.
2. Pull `Documents/corvus/session-*/` off the phone (Xcode → Devices → the app's container).
3. Label a sample by hand into `labels.json`
   (`{"frames/x.jpg": {"holding": true, "item_id": "cereal"}}`).
4. Run:

```bash
export GEMINI_API_KEY=... ANTHROPIC_API_KEY=...
python3 corvus-tools/detector-bench.py path/to/session-*/frames \
    --labels labels.json --models gemini-flash-lite,claude-haiku
```

Precision matters more than recall here: a false positive is an interview the
participant should never have been asked, which contaminates the session. A
false negative costs one data point.

The script extracts the prompt and watchlist from the Swift sources at run time,
so a benchmark can never measure a prompt the app does not send.

## Measured detector latency

One frame, four backends, 2026-08-27 (p50 of a single call -- indicative, not a
benchmark):

| Backend | Model | Latency |
|---|---|---|
| Gemini Flash-Lite | `gemini-2.5-flash-lite` | ~1.5 s |
| Gemini Flash | `gemini-2.5-flash` | ~1.6 s |
| Claude Haiku | `claude-haiku-4-5` | ~2.4 s |
| OpenAI mini | `gpt-5-mini` | ~4.8 s |

All four agreed the test frame (a shelf, no hands) was `holding: false`, which
is what the prompt's "hands must be visible" rule demands.

**This constrains `TriggerPolicy`.** A trigger needs `consecutiveHits` samples
inside `streakWindow`, and the coordinator holds one detector call in flight at
a time -- so the real sample rate is `1 / max(sampleInterval, latency)`, not the
configured 1 fps. At 6 s, the Gemini backends and Haiku fit; `gpt-5-mini` needs
roughly double the window before it can fire at all.

Worth watching in the logs: the models do not agree on what `confidence` means
when `holding` is false (Gemini returned 0.00, Claude 1.00, OpenAI 0.86 -- some
read it as "confidence in this product", others as "confidence in my answer").
It is harmless today because the confidence gate is only reached once an item
has matched, but it is a prompt-tuning item.

## Known open questions

- The watchlist and its questions are placeholders pending the study design.
- Model ids in `CorvusConfig` and `detector-bench.py` need checking against
  current provider docs before any benchmark number is trusted.
