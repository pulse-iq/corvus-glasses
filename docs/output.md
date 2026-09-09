# Output

Local logs and interview records land in the app's Documents container. Realtime
missions also persist full recordings and authoritative interview results in the
recording bucket so a phone disconnect does not lose the only copy.

```
Documents/corvus/
└── session-<timestamp>/
    ├── events.jsonl          append-only trace of the whole run
    ├── intercepts/<uuid>.json    the deliverable
    ├── missions/<uuid>/manifest.json    mission state and received events
    ├── audio/                answer recordings (turn-based interceptors only)
    └── frames/               sampled frames (off by default)
```

One session directory per app launch. The directory name — `session-<timestamp>`
— is also the prefix used by legacy standalone realtime recordings. Mission
recordings use mission and segment UUIDs instead; their manifest retains the
phone session name.

## Full-mission recordings

```text
hack/missions/<missionId>/
└── segments/<segmentId>/
    ├── recording.mp4
    ├── manifest.json
    └── interviews/<interceptId>.json
```

One recording spans the welcome, ambient shopping audio/video, and all interviews
in an uninterrupted mission. The manifest contains recording status, egress ID,
recording start time, mission start/end information, and interview
references. A recorder reported as finalizing is not yet a saved file; the
companion mission-status endpoint reconciles its eventual result.

Local `InterceptRecord` adds optional `missionID`, `segmentID`,
`recordingOffsetSeconds`, and `authoritativeTurns`. Existing records remain
readable. Authoritative turns retain ordered role/text/timestamp values; the
question/answer view remains available for existing consumers. The greeting and
ambient shopping audio do not belong to individual interview transcripts.

Cloud recordings cannot reconstruct footage lost during an uplink outage. This
prototype retries within the same room and ends visibly if recovery fails;
replacement-room recording and stitching are outside the implemented scope.

## Getting it off the phone

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier <bundle-id> \
  --source Documents/corvus --destination <destination>
```

`xcrun devicectl list devices` gives the UDID. The bundle identifier is whatever
`Signing.xcconfig` resolved to — `com.meetcorvus.glasses` unless you changed it.

## `events.jsonl`

One JSON object per line, appended as things happen. Flat on purpose: JSONL is
meant to be greppable and loadable into a dataframe without a schema library.

`kind` discriminates; the other fields carry whatever that kind needs.

| `kind` | Written when |
|---|---|
| `watcher_started` / `watcher_stopped` | the watcher runs or stops |
| `detection` | a frame came back from the detector |
| `detector_error` | a frame did not |
| `trigger` | a primitive fired |
| `trigger_suppressed` | a primitive would have fired but a gate stopped it |
| `intercept` | an intercept completed |
| `video_published` / `video_publish_failed` | the realtime path published the glasses feed into the room, or could not |

`trigger_suppressed` is the one to read when tuning. It carries the `decision`
that stopped it, which is the difference between "the model never saw it" and
"the model saw it and a cooldown ate it" — problems with opposite fixes.

`detection` rows also carry the full `observation`, including the frames where
nothing matched. That is what lets a new primitive be developed against a trip
already walked rather than a new one: the frames where a product *left* someone's
hands are exactly the ones a flat `holding: false` throws away.

## `intercepts/<uuid>.json`

The deliverable. One `InterceptRecord` per intercept:

| Field | What |
|---|---|
| `studyID`, `itemID`, `itemName` | what the intercept was about |
| `primitive` | which primitive earned it — `holding`, `dwell`, … |
| `triggeredAt`, `endedAt`, `confidence` | when and how sure |
| `turns[]` | each question, its transcript, timings, and audio path |
| `questionsAsked`, `reasks` | substantive questions, re-asks excluded |
| `interceptor`, `brain` | which mode ran it, and whose transcript this is |
| `endedBecause` | how a normal intercept finished |
| `abortReason` | set only when something went wrong |
| `routeMode`, `routeInput`, `routeOutput`, `routeMatchedGlasses` | what the audio route actually resolved to |
| `videoSource` | what the room published, on modes that publish video |
| `recordingKey` | object key of the room recording, on modes that produce one |

`routeMatchedGlasses` and `videoSource` exist because both have failed silently
before: a wrong microphone cost a session once, and a mis-wired video track
produces a call that sounds completely normal and records black. Neither shows up
as an error, so both are written down.

Each `turn` also carries `meterTrace` — the recorder's own level readings, one
per 100 ms. That is the ground truth for tuning silence detection, and the only
measurement of it that has not already misled us once.

`brain` says where the transcript came from. On the realtime path it is always
the agent's: phone-side reconstruction was removed because it mis-paired
questions with answers whenever the next question arrived before the previous
answer's final text. Authoritative or nothing — if the worker dies before
publishing, the record has zero turns and an `abortReason`.

## Audio

`audio/` holds one recording per answer, referenced by `turns[].audioPath`
relative to the session directory so a pulled folder stays portable.

Only the turn-based interceptors write here. The realtime path never records
answer audio to the phone — its audio is in the room recording instead.

## Frames

`frames/` is off by default. It is how the offline benchmark corpus in
`corvus-tools/` gets built, not something to leave running during a session:
every sampled frame is written alongside its verdict.

## Legacy standalone video

The following describes the retained standalone realtime interceptor. Mission
recordings follow the full-mission layout above and include footage before an
intercept when capture and the uplink are healthy.

Realtime intercepts are recorded off the room and uploaded straight to object
storage by the media server — the phone holds no storage credentials and uploads
nothing. The only trace on the phone is `recordingKey` on the record, which is a
pointer rather than a path: the bucket is not addressable from the device.

```
<bucket>/<prefix>/session-<timestamp>/<start>.mp4
```

Within a session, sorting by name sorts by time.

Nothing else records video. The watcher's frames are 768px stills at ~1fps and
mostly discarded, and the other two interceptors never open a room. Switching
the style to `conversational` or `scripted` therefore records no video at all,
and the first symptom of expecting otherwise is an empty bucket rather than an
error.

**The pickup itself is not in any recording.** The moment that triggered the
intercept happened seconds before the room existed. Capturing it would mean
recording on the phone, which the glasses cannot do for you: the DAT surface is
stream configuration, frame callbacks, and photo capture, with nothing that
writes to glasses storage or hands back a file.

## Related

- [studies.md](studies.md) — what generates these records
- [realtime.md](realtime.md) — where recordings come from
