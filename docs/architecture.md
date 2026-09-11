# Architecture

Corvus runs *intercept interviews*. Someone wearing Meta Ray-Ban glasses picks
up a product the study is watching for; the app notices and asks them about it,
out loud, in the moment. The point is research data captured at the moment of
choice rather than recalled afterwards in a room.

The system is two halves with one seam between them.

```
                    the watcher                              the intercept
   ┌────────────────────────────────────────────┐   ┌──────────────────────────┐
   glasses ──DAT──> phone ──HTTPS──> vision model ──> Trigger ──> Interceptor ──> InterceptRecord
   └────────────────────────────────────────────┘   └──────────────────────────┘
        24fps in, ~1fps out          one call per frame        speaks, listens, writes
```

The **watcher** is cheap continuous vision that decides *whether this moment is
worth interrupting*. The **intercept** takes that decision and conducts the
conversation. They meet at a single value, `Trigger`, and nothing downstream of
it needs to know which primitive fired or which model saw it.

## Mission ownership

In the participant flow, `MissionCoordinator` owns the room and capture lifetime.
Start Mission snapshots the study, camera source, and voice engine. The worker
starts one recording, speaks a welcome, then waits for the existing watcher to
send interview briefs through that room. Individual interviews keep the same
study prompts and trigger policy, but `end_intercept` now returns the mission to
quiet shopping rather than deleting its room.

Readiness gates detection during setup, voice preparation, and reconnects. A
readiness loss clears accumulated visual evidence while preserving earned
cooldowns. Async callbacks carry a generation so a late detection or connection
cannot restart an ended mission. End Mission stops publication and camera capture.
There is no mission time limit and no timer is shown; the safety nets are the
worker's phone-heartbeat timeout and the gateway's worker-presence check.

The mission worker is in `agent/corvus_mission.py`, its voice adapter in
`agent/corvus_mission_voice.py`, and recording/storage adapters in
`agent/corvus_mission_storage.py`. Legacy standalone interviews remain in
`agent/corvus_intercept.py`. See [realtime.md](realtime.md) for the standalone `web/` token
service and protocol rollout requirements.

## The watcher

All on-device except the vision call. No server is involved.

**Sampling.** `FrameSampler` throttles the glasses' 24fps stream to ~1fps,
downscales to 768px on the longest edge, and encodes JPEG at q0.7. Everything
above ~1fps is spend without extra signal — a shopper holds a product for
seconds, not frames — and 768px keeps a label legible while staying inside the
cheap image tier at every provider.

**Detection.** `ProductDetector` sends one frame and the watchlist and gets back
a structured verdict. Four implementations ship, swappable in Settings, so the
same frames can be compared across vendors. Measured p50 round-trips:

| Detector | p50 |
|---|---|
| Gemini Flash-Lite (default) | ~1.5s |
| Gemini Flash | ~1.6s |
| Claude Haiku | ~2.4s |
| gpt-5-mini | ~4.8s |

Effective sample rate is `1 / max(interval, latency)`, so a slow detector does
not merely cost latency — it can make a streak arithmetically impossible to
complete. See [Tuning](#tuning) below.

`DetectionPrompt.system(for:)` is the single source of truth for the vision
prompt. The offline benchmark in `corvus-tools/` extracts it from the Swift
source at runtime rather than keeping a copy, so the two cannot drift.

**Primitives.** A verdict is read by four *primitives*, each a different claim
about what the wearer is doing. They differ in their predicate, not in what they
can be aimed at, so each one takes a target — a single product or a whole shelf
section.

| Primitive | Fires when | Targets | Priority |
|---|---|---|---|
| `comparing` | Two of a section's products in the hands at once | sections | 30 |
| `examining` | Held up close and read, rather than carried | products, sections | 20 |
| `holding` | In the hands at all | products, sections | 10 |
| `dwell` | Stopped in front of a section, hands empty or not | sections | 0 |

Priority breaks ties when several fire on one frame, ordered by how much the
moment narrows down what to ask: someone weighing two jars against each other
has told you more than someone merely holding one.

`comparing` and `dwell` cannot target a single product — two of the same item is
not a comparison, and you cannot stand in front of one jar. A study that tries
fails to load rather than silently doing nothing.

**The state machine.** `TriggerStateMachine` is pure and clock-injected
(`observe(_:at:)`), which is what makes it testable without a phone. It gates
each primitive on:

- `minConfidence` — below this the frame does not count toward a streak at all
- `consecutiveHits` within `streakWindow` — one frame is not evidence; the model
  will occasionally see a jar in a hand that is reaching past it
- `cooldown` — per target, per primitive
- `globalCooldown` — quiet period after any intercept ends
- `maxInterceptsPerTrip` — a ceiling, not a target

Hits **age out** of `streakWindow` rather than being cleared by a miss, so a
blurred frame between two good ones still fires. That is deliberate: at ~1fps a
single bad frame is common and should not reset the evidence.

<a id="tuning"></a>
**One arithmetic trap.** `streakWindow` must exceed
`consecutiveHits × detector round-trip`, or the streak can never complete and
the watcher will simply never fire. With the default `holding` policy — 2 hits
in 6s — a detector at 4.8s p50 cannot satisfy it.

## The intercept

`Interceptor` is one protocol with two selectable implementations, chosen at
runtime in Settings → Corvus → Intercepts → Style, plus the mission coordinator,
which takes over as the interceptor for the length of a mission.

| Mode | Model in the loop | Server needed | Turnaround |
|---|---|---|---|
| `conversational` | one call per turn | none | ~4.0s |
| `liveKit` (default) | a realtime voice model | token endpoint + deployed agent | sub-second |

**Conversational** sends the *answer audio* straight to the model and gets back
`{transcript, next_question, is_reask, rationale}` in one round trip — no
separate transcription step, and the model hears hesitation, which is signal for
when to stop. The ~4.0s turnaround is ~1.2s of silence detection plus ~2.4–3.6s
of model time, scaling with upload size.

**Realtime** publishes the phone's microphone into a room and lets a deployed
worker bridge it to a realtime voice model. It is the only mode that needs
anything outside the phone, and the only one that records video. See
[realtime.md](realtime.md).

Every interceptor returns an `InterceptRecord` whether or not it succeeded — an
intercept that half-happened is still data, and the watcher has to be released
either way. A failed one carries `abortReason`.

## Audio

The DAT SDK is camera-only; its entire permission set is `camera`. Glasses audio
works because iOS routes to them as an ordinary Bluetooth headset, outside
Meta's SDK entirely. Both directions work while DAT is streaming video.

The trade-off is a profile choice iOS makes, not one Corvus controls: A2DP gives
full-bandwidth output but no microphone; HFP gives both at call quality.

`GlassesAudioSession` selects the glasses **by name**, because a participant's
earbuds will otherwise win the route and nothing will say so.

## The glasses stream

The stream view model (upstream VisionClaw code) owns the DAT session and
camera; `Corvus/GlassesLink.swift` watches it and names the wait. Settings has
three levers -- tier, frame rate, codec -- and changing one replaces the camera
on the live session: stop the old camera, wait for the SDK to report it
detached, add the new one. A second change while a replacement is still
starting is held and applied 1.5 s after the new stream comes up.

**Known behaviour, deliberately left to the self-heal.** A replacement that
asks for the high tier (720p, or 30 fps) soon after a camera teardown fails
with `videoStreamingError` within about 150 ms, whether the settle is 1.5 s or
4 s. Stepping down never failed in testing. When a stream stops for any reason
while the session survives, the view model detaches the dead camera and adds a
new one, which brings video back in about 7 s; the retry loop then restarts the
session if the SDK still reports a stale capability. This is the recovery
missions rely on for any mid-stream stop, and it is what covers the lever case
too. When testing levers, change one, let the picture return, then change the
next.

## Where things live

| Path | What |
|---|---|
| `Corvus/FrameSampler.swift` | throttle, downscale, encode |
| `Corvus/DetectionPrompt.swift` | the vision prompt, single source of truth |
| `Corvus/ProductDetector.swift`, `Corvus/Detectors/` | the four backends |
| `Corvus/TriggerPrimitives.swift` | primitives and their per-primitive policies |
| `Corvus/TriggerStateMachine.swift` | evidence, gates, `Trigger` |
| `Corvus/WatcherCoordinator.swift` | wiring: frames in, intercepts out |
| `Corvus/Study.swift`, `Corvus/WatchItem.swift` | the study config shape |
| `Corvus/Interceptor.swift` | the seam, and the record format |
| `Corvus/RealtimeMedia.swift`, `Corvus/LiveKitRealtimeMedia.swift` | the only door into upstream's LiveKit session |
| `Corvus/GlassesStreamQuality.swift` | the stream tier picker; the tier is what selects Wi-Fi or Bluetooth |
| `Corvus/GlassesLink.swift` | link monitor: per-device link state and thermal diagnostics, the refused-session detector that backs off the retry loop, and the wait-state wording that names which layer is pending |
| `Corvus/*Interceptor.swift` | the conversational and realtime implementations; the mission coordinator is the third |
| `Corvus/CorvusLog.swift` | the session log |
| `agent/` | the deployed realtime worker |
| `web/` | standalone Vercel mission/token service and cleanup watchdog |
| `corvus-tools/` | offline detector benchmark |

Corvus is a fork of [VisionClaw](https://github.com/Intent-Lab/VisionClaw) and
owns its own files: everything above lives under `Corvus/`, and upstream files
carry only small seams. That is what keeps pulling from upstream survivable.

## Related

- [studies.md](studies.md) — configuring what it watches for and what it asks
- [output.md](output.md) — what a session produces and how to get it off the phone
- [realtime.md](realtime.md) — the realtime interceptor
