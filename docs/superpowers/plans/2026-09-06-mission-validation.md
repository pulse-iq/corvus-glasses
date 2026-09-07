# Mission prototype validation

> Historical record of the initial companion-repository implementation. The
> backend has since moved into this repository's `web/` app; see
> [web setup](../../../web/README.md) and the web-monorepo validation notes.


## Delivered scope

The app defaults to explicit Start Mission / End Mission controls. Starting owns
camera/microphone capture, one LiveKit room, the welcome, and a continuous room
recording. Product detection can begin interviews only after the worker reports
that recording, model connection, and audio subscription are ready. Between
interviews the model receives no shopper audio or camera video; published tracks
remain available to recording. The background deadline is 900 seconds, with no
countdown or one-minute warning.

The existing Corvus study brief and detection/cooldown rules remain in use.
Individual authoritative interviews are saved in S3 and locally, linked to the
mission recording. Late connection completions cannot restart an ended mission.
Repeated readiness heartbeats reconcile missed state. End retains partial
interviews even if voice interruption fails, and recording upload time does not
extend the recorded mission end timestamp.

The glasses branch is `codex/mission-session-prototype`. The actual token backend
is a separate repository: branch `codex/glasses-mission-gateway`, commit
`57ab9fc9`, worktree `/private/tmp/corvus-mission-gateway`. Its original `dev`
checkout was not changed. Neither branch has been pushed or deployed.

## Implementation choices

- The token service uses its existing shared bearer credential, with Redis
  allocation claims and permanent terminal tombstones. This is prototype shared
  ownership, not individual shopper accounts.
- A durable Vercel Workflow is enqueued before room allocation. It independently
  stops orphan recording when both phone and worker disappear. Worker shutdown
  and authenticated status/end routes also reconcile recording completion.
- Reconnection reuses the same room, identity, and deadline. A lost worker ends
  the mission visibly; automatic replacement rooms and stitched recordings are
  deferred. A new mission gets a new ID.
- Voice sessions are replaced after the welcome and each interview, and after
  four idle minutes. This conservative interval is shorter than the planned
  eight-minute refresh. No new model session is allocated at an eligible trigger.
- Swift storage and controls are consolidated into the coordinator/current
  view; Python protocol/lifecycle is in `corvus_mission.py` and recording/storage
  is in `corvus_mission_storage.py`, rather than every file proposed in the plan.
- LiveKit Agents and Google/OpenAI plugins are pinned to 1.8.0; google-genai is
  pinned to 2.22.0. Legacy standalone calls remain available through the existing
  flow with `corvus.legacySessionMode` enabled in UserDefaults.

## Automated validation

| Check | Result |
|---|---|
| iOS simulator build and XCTest | 47 tests passed on iPhone 17 Pro / iOS 26.5, Xcode 26.6 |
| Python mission lifecycle/storage/voice tests | 33 tests passed |
| Companion gateway Vitest | 16 tests passed across three files |
| Companion gateway TypeScript | `tsc --noEmit` passed |
| Vercel Workflow compilation | Succeeded; generated manifest and routes contain mission watchdog |
| Full companion Next build | Blocked by DNS resolution of existing Google Fonts requests (`fonts.googleapis.com`, Inter/Lora) |

The simulator excludes the existing device-only mock SDK tests when
`MWDATMockDevice` cannot be imported. This permits the shared mission tests to
run; it does not substitute for hardware tests.

Reproducible commands:

```sh
PYTHONPATH=agent python -m unittest discover -s agent/tests -v
PYTHONPATH=agent python agent/tools/mission_voice_smoke.py
```

The voice smoke command uses configured LiveKit/Gemini credentials, incurs API
usage, and creates/deletes a temporary room. Optional `--env-file` needs
`python-dotenv` in the test environment. It never captures a real microphone or
camera and does not start egress.

In the companion worktree:

```sh
./node_modules/.bin/vitest run utils/glasses app/api/glasses/mission-status/route.test.ts
./node_modules/.bin/tsc --noEmit
```

The successful iOS invocation uses `CameraAccess.xcodeproj`, scheme
`CameraAccess`, simulator destination
`platform=iOS Simulator,id=1D0DA2EC-E802-4FA5-97CC-C6F01F494080`,
`CODE_SIGNING_ALLOWED=NO`, and `test`. It reused the cached package checkout.

## Live smoke findings

The live probe exposed and drove fixes for a silent welcome and SDK audio-track
cleanup. The final harness checks nonzero PCM samples rather than counting silent
packets, validates each product-specific transcript, checks output-track cleanup,
and asserts no model factory invocation during begin-intercept.

Final run passed with audible welcome and three correct opening-question
transcripts in the same room. First audible output after begin measured 0.996s
(milk), 1.096s (bread), and 1.044s (coffee). Model factory calls remained unchanged
at each trigger (four total: welcome plus three preparations). Each prepared
session had one published agent audio track; close left zero. Repeated cleanup
succeeded and the temporary room was deleted. The command exited successfully.
These three synthetic samples do not establish a p50/p95 latency target or
real-device performance. The pinned SDK logged a deprecated metrics event and
one FFI-handle cleanup warning; neither prevented output or room deletion.

## Remaining acceptance work

- Coordinated gateway/worker deployment and installation of this iOS build.
  The deployed preview still implements its previous contract.
- Real 15-minute glasses mission with welcome, several interviews, quiet shopping,
  background/lock, incoming-call, network, glasses-disconnect and worker-failure
  cases. The paired iPhone was unavailable during this session.
- Actual egress upload and MP4 inspection: camera footage, ambient/agent/shopper
  audio, full duration, transcript offsets, gap behavior, file size, and retained
  final status after app exit. Recording adapters were tested with fake API/S3
  responses; the live voice probe did not record.
- Measure at least ten eligible triggers on hardware before claiming a latency
  target. Verify long-duration provider resumption and idle refresh.
- Worker container build (Docker was unavailable locally). Python source/tests
  ran with Python 3.13.14; the Docker image uses Python 3.12.

Source ownership and configuration details are in
[integration evidence](2026-09-06-mission-integration-evidence.md) and the
companion `docs/glasses/mission-gateway.md`.
