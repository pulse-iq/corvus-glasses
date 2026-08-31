# The realtime interceptor

`liveKit` is the default interceptor. It trades the simplicity of the turn-based
modes -- which need nothing but a model key -- for sub-second turnaround: the
phone publishes its microphone into a room, a deployed worker bridges that room
to a realtime voice model, and the conversation happens at conversational
latency.

It is the only interceptor that needs anything outside the phone, and the only
one that produces video. Without a token endpoint and its token, switch the
style to `conversational`, which needs no server at all.

```
phone ──POST /livekit-token──> token endpoint
                                 ├─ creates the room
                                 ├─ dispatches the worker by name
                                 └─ returns a short-lived room token whose
                                    metadata carries the intercept brief
phone ──audio/video──> media server <──> deployed worker <──> realtime model
                              └── room recording ──> object storage
```

## Using it

Two values, both already in `Secrets.swift.example`:

- **`cloudGatewayURL`** — the base URL of the token endpoint, no trailing slash.
  The app appends `/livekit-token` and `/health` itself. It must be `https`:
  `Info.plist` allows plaintext for local networking only, so an `http://`
  address is refused by App Transport Security rather than failing in any way
  that points at the cause.
- **`cloudGatewayToken`** — per-person, not in this repo. Ask whoever runs the
  deployment.

Both can be overridden on the device under Settings → Cloud gateway, and **the
stored value wins over the compiled default**, so a phone that already has one
keeps it until you change it there.

Then switch Settings → Corvus → Intercepts → Style to Realtime. Settings shows a
gateway status line that distinguishes a rejected token from an unreachable
server — they need opposite fixes.

You do **not** need to deploy anything to use this. The worker already runs in
the cloud.

## The phone owns the prompt

The full intercept prompt is composed on the device by
`InterceptPrompt.realtime(study:item:)` and shipped as text in the token
metadata. The worker never learns what a study is.

That is the arrangement worth preserving: rewording a study, changing its
research goal, or adding an item needs no redeploy of anything.

## The metadata contract

The phone sets, and the worker reads:

| Key | Meaning | If it goes missing |
|---|---|---|
| `corvus.mode == "intercept"` | this room is an intercept, not an ordinary assistant session | **the brief is ignored and the session runs as a generic assistant** |
| `corvus.sessionId` | the phone's session directory name, reused as the recording prefix | recordings scatter one-per-prefix instead of grouping by session |

Both fail **quietly**. A phone and a worker that disagree about `mode` produce no
error at all — the intercept just sounds like a prompting problem rather than a
contract one. Both sides must move together.

The token endpoint passes the `corvus` object through untouched and never
inspects it, so it needs no change when these keys do.

## Dispatch is explicit

The worker registers with an agent name and the token endpoint dispatches it by
that name. This is what lets Corvus share a media-server project with other
agents without either gatecrashing the other's rooms.

**If the agent name is ever removed, the worker auto-dispatches to every room in
the project** — including other products' live sessions. Do not remove it.

## The worker owns the transcript

The worker hooks conversation items as they are added — ordered, complete, and
attributed — and publishes the transcript as JSON on a data topic **before**
deleting the room. Deleting the room closes the engine, and anything published
after that fails.

That published payload is also the only channel back to the phone: it is how the
device learns `recordingKey`. Corvus has no backend to ask later.

## Ending

The model ends the intercept by calling its one tool, `end_intercept`. Three
backstops sit behind it:

| Backstop | Default | Env var |
|---|---|---|
| silence exit | 45s | `CORVUS_IDLE_EXIT_SECONDS` |
| hard ceiling | 180s | `CORVUS_INTERCEPT_CEILING_SECONDS` |
| worker-join timeout | 20s | — |

Neither env var is set in the deployment today, so both run on the in-code
defaults above.

The tool name appears in three places that must agree: the tool definition in
the worker, the closing instruction in the phone's prompt, and the deployed
build. A rename in two of the three produces a model that never stops.

## Recording

Room-composite recording, started and stopped by the worker, uploaded by the
media server directly to object storage. The phone holds no storage credentials.

Four things about it that are not obvious:

- **Started before the opening line, and awaited.** The request takes about a
  second, and the interceptor speaks the moment the session opens, so firing
  them concurrently loses the first question. Awaiting narrows the gap without
  closing it: the compositor's first *encoded* frame still lands 1.2–1.5s after
  the call returns. Closing it properly means starting the recording at room
  creation, in the token endpoint, so the compositor boots alongside the worker.
- **Stopped before the room is deleted.** The recorder is a room participant
  that never leaves on its own; deleting the room out from under it aborts the
  recording and the file is lost rather than uploaded.
- **Grid layout, not speaker-following.** The glasses feed is the only video in
  the room and the interceptor is a disembodied voice, so a speaker-following
  layout cuts away from the wearer's POV to an empty tile every time the
  interceptor talks.
- **Missing credentials are not an error.** No bucket or no keys logs a line and
  runs the intercept unrecorded. A failed recording is worth far less than the
  conversation it would otherwise cost.

The preset currently asks for 30fps against a 24fps source. Measured on a real
recording: 1004 frames over 33.47s, 21% of them near-empty, because the
compositor pads with duplicates to reach its preset. Encoding options pinned at
24fps would spend that bitrate on real frames instead.

## Video publishing, and a silent failure

Wire the buffer capturer **before** publishing its track, never after. A buffer
track has no camera to open: until something pushes into it, it has no frames and
no dimensions. Publish first and the track goes out empty — it encodes as black
while frames keep arriving into the capturer the new track replaced.

Nothing fails loudly. The call connects, the intercept sounds normal, and the
only evidence is a black recording. That is why `events.jsonl` carries
`video_published` / `video_publish_failed` and why `InterceptRecord.videoSource`
reads `none` when a call went out with no video at all.

## Operating the worker

Only needed by whoever owns the deployment; collaborators can skip this entirely.

```bash
cd agent/
bash setup_livekit_toml.sh              # regenerate config after editing agent/.env
lk agent deploy --secrets-file .env
lk agent status                         # must run from agent/ — reads livekit.toml
lk agent logs --log-type deploy         # streams; needs a timeout in scripts
```

`lk` commands read `livekit.toml` and must run with `agent/` as the working
directory. **`lk agent deploy` can print a validation failure while exiting 0**,
so read its output rather than its exit status.

The Dockerfile enumerates the worker's sources by name. Adding or renaming a
module means editing it too — and when it is wrong the build fails while the
cloud keeps serving the last image that worked, so the symptom is an agent
running old code, not an agent that is down.

Credentials are duplicated between the worker's environment and the token
endpoint's by necessity. Drift between them surfaces as "no worker joined the
room", which looks like an agent bug rather than a stale key.

## Related

- [architecture.md](architecture.md) — how a trigger reaches an interceptor
- [output.md](output.md) — where recordings and transcripts end up
