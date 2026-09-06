# Persistent Shopping Mission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run button-started shopping missions with immediate interviews inside an already connected room, continuous mission recording, and an invisible 15-minute failsafe.

**Architecture:** A Corvus mission coordinator owns iOS capture and room lifetime. A mission worker owns successive voice conversations, recording, and the authoritative deadline; interview completion never deletes the room. Prepare clean voice sessions between interviews while the existing cooldown runs, rather than relying on Gemini history deletion.

**Tech Stack:** Swift/SwiftUI, XCTest, LiveKit Swift SDK pinned in this repo to 2.16.0, Python 3.12 worker, LiveKit Agents/Google/OpenAI plugins, existing S3 recording destination. Python package declarations currently contain minimum versions, not a deployment lock.

**Spec:** `docs/superpowers/specs/2026-09-06-mission-session-design.md`

**Status:** Local implementation tasks and proposed wire contract are written. Task 1 must resolve the external token-service ownership and verify deployed SDK/model behavior before transport or backend implementation. This document does not authorize application changes or deployment.

## Global Constraints

- iOS Corvus prototype; Android remains the upstream sample.
- Button-only Start Mission and End Mission. No spoken activation.
- One room and a prepared voice agent for the mission, with recovery when necessary.
- Record the entire active mission: camera video, shopper/ambient audio, and agent speech.
- Hard maximum mission duration of 15 minutes (900 seconds), enforced as a background failsafe. Do not display remaining time or a one-minute warning.
- Preserve existing product detection, study prompts, interview limits, and cooldown rules.
- Keep individual interview transcripts and link them to offsets in the mission recording.
- No application code or deployment until the planning phase is complete and implementation is authorized.
- Preserve ordinary assistant calls, legacy one-interview mode, and local development interceptors.
- No video or ambient shopping audio goes into the voice model; microphone/video publication to recording continues while the model is quiet.
- No model, recorder, or room startup on a normal eligible trigger. If preparation is incomplete, remain unavailable for interviews and discard triggers.
- No visible timer or advance warning; reaching the failsafe produces the ordinary ended state and a persisted end reason.

## Evidence and implementation choices

The current phone starts/stops LiveKit per interview; the worker ends by deleting the room. `LiveKitSession.stop()` also restarts camera preview. The watcher has untracked async detection/interview completions and resets its trigger machine in `start()`. Mission cancellation and temporary readiness gating must account for all four behaviors.

Google documents connection resets around ten minutes independently of its audio session lifetime. Current upstream LiveKit Google code warns that removing chat history does not remove server-side messages. Neither the current upstream adapter nor documentation proves the behavior of the deployed minimum-version dependencies.

Choose a clean voice session after the welcome and after every interview, prepared while the watcher is gated and its cooldown runs. Keep the mission room and recorder. Use fixed mission policy as initial system instructions and deliver the device-composed interview brief in the explicit begin reply. Verify the selected model actually honors that brief without reconnecting. Refresh an unused prepared voice session at eight minutes of voice-session age, independently of the mission clock. Do not reset an active interview just because its age reaches eight minutes; handle provider resumption and errors separately.

References checked during planning:

- https://ai.google.dev/gemini-api/docs/live-api/session-management
- https://github.com/livekit/agents/blob/main/livekit-plugins/livekit-plugins-google/livekit/plugins/google/realtime/realtime_api.py
- https://docs.livekit.io/agents/multimodality/text/
- https://docs.livekit.io/reference/other/egress/api/

## File boundaries

New iOS files, all under `samples/CameraAccess/CameraAccess/Corvus/`:

| File | Responsibility |
|---|---|
| `MissionProtocol.swift` | Codable envelopes, snapshot, brief, result, recording segment |
| `MissionState.swift` | Pure state/deadline/generation logic without media dependencies |
| `MissionCoordinator.swift` | MainActor orchestration, readiness, cancellation, capture lifecycle |
| `MissionTransport.swift` | Text-stream request/event adapter with retries and sender checks |
| `MissionStore.swift` | Atomic local manifest/result writes and reconciled server state |
| `MissionControls.swift` | Start/End, recording and mission status; no timer |

New worker files under `agent/`:

| File | Responsibility |
|---|---|
| `corvus_mission_protocol.py` | Validation and transport-neutral message/state types |
| `corvus_mission.py` | Mission lifecycle, one interview at a time, deadline, dispatch |
| `corvus_mission_voice.py` | Prepared voice session, input gating, greeting/interview playback |
| `corvus_mission_recording.py` | Egress start/stop/status and segment metadata |
| `corvus_mission_store.py` | Recoverable immutable mission events/results in existing object storage |
| `tests/test_mission_protocol.py` | Protocol validation, deduplication, conflicts |
| `tests/test_mission.py` | Async lifecycle/race/deadline tests with fake adapters |
| `tests/test_mission_recording.py` | Egress transitions and persistence failure tests |
| `tests/test_mission_voice.py` | Input isolation, clean-session preparation, stale callbacks |

Existing seams: `StreamSessionView.swift`, `StreamSessionViewModel.swift`, `OpenClaw/LiveKitSession.swift`, `OpenClaw/LiveKitStreamView.swift`, `Corvus/WatcherCoordinator.swift`, `Corvus/TriggerStateMachine.swift`, `Corvus/LiveKitInterceptor.swift`, `Corvus/Interceptor.swift`, `Corvus/CorvusConfig.swift`, `Corvus/CorvusLog.swift`, `agent/main.py`, `agent/Dockerfile`, `agent/requirements.txt`, and the three repository docs.

The Corvus and CameraAccessTests Xcode folders are synchronized groups, so new Swift files should not require individual pbxproj source entries. Verify target membership rather than rewriting the project.

## Proposed protocol v1

Use dedicated reliable text streams: `corvus.mission.command` and `corvus.mission.event`. Existing `lk.transcription` remains live captions; existing `corvus.transcript` remains the legacy contract. Do not route control payloads through conversational text input.

Every message uses this envelope (JSON example is a complete command):

```json
{
  "version": 1,
  "missionId": "3A33FCA4-926B-4582-A811-3010627BEDB1",
  "segmentId": "D1B6D88D-93F8-44E5-93A9-A10FB7DF1921",
  "operationId": "A5042095-46CC-47A7-8FA1-8F97EB7E45C4",
  "type": "begin_intercept",
  "interceptId": "FA5660A6-3560-44D0-9A18-0505CFBF3757",
  "payload": {
    "studyId": "milk-study",
    "itemId": "milk",
    "itemName": "milk",
    "openingQuestion": "What made you reach for that one?",
    "instructions": "Ask the opening question exactly, then conduct the supplied study interview. Finish by calling end_intercept.",
    "triggeredAtMs": 1788717600000,
    "primitive": "holding",
    "confidence": 0.95
  }
}
```

These are fixture identifiers, not actual missions. Runtime IDs are generated UUIDs. Instructions in actual messages come unchanged from `InterceptPrompt.realtime(study:subject:)`.

### Fields and bounds

- `version`: integer 1. Unknown versions are rejected, never generic-assistant fallback.
- `missionId`, `segmentId`, `operationId`, optional `interceptId`: validated UUID strings.
- `type`: exact command/event discriminant below.
- `payload`: typed per discriminant, not an arbitrary dictionary at call sites.
- Maximum encoded control message: 64 KiB. Maximum instructions: 32 KiB UTF-8. Persist long results as immutable objects and announce their result key; do not truncate research transcripts to fit an envelope.
- Authenticated phone identity comes from the room token; validate command sender against it. Phone accepts events only from its assigned named-dispatch worker, not any participant whose name starts with `agent`.
- Deduplicate by `(missionId, operationId)` plus a canonical payload hash. Same ID/same payload replays the outcome; same ID/different payload returns `operation_conflict`.
- `interceptId` is unique across operations too: retrying a begin under another operation ID cannot reopen that interview.

### Commands and events

| Direction | Type | Payload/result |
|---|---|---|
| Phone → worker | `client_ready` | camera frame received, microphone published; worker also checks tracks |
| Phone → worker | `begin_intercept` | Brief above; terminal reply is accepted/rejected, not interview completion |
| Phone → worker | `cancel_intercept` | Active ID and reason; normal finish releases only interview |
| Phone → worker | `sync` | Last applied server sequence; returns current snapshot and recoverable result references |
| Phone → worker | `ack` | Highest durably applied contiguous sequence |
| Phone → worker | `end_mission` | Reason `user_ended`; valid in every nonterminal state |
| Worker → phone | `accepted` / `rejected` | Original operation ID, code, optional active interview ID |
| Worker → phone | `state` | Snapshot with incrementing sequence, phase, server time, start/deadline, recording state, voice readiness |
| Worker → phone | `intercept_completed` | Interview ID, immutable result key, segment IDs, timestamps, end/abort reason |
| Worker → phone | `recording` | Segment ID, egress ID, key, status, recording start/end timestamps |
| Worker → phone | `mission_ended` | End reason, ended time, result references, recording finalization state |

Every event has a server sequence and stable event ID; acknowledge only after an atomic local write. Snapshots preserve sequence across reconnect. Persist events before notification, so a lost final message does not lose the only record. Late result arrival may enrich saved data, but never reopen the mission.

### Timing policy

| Concern | Initial prototype policy |
|---|---|
| Initial setup | 45 s total wall-time bound from button press; includes existing ticket request timeout |
| Command delivery | Send at elapsed 0, 1, 3, 7 s; all retries reuse operation ID; fail/reconcile at 10 s |
| Initial recorder/voice preparation | Must complete inside remaining setup budget |
| Interview silence/ceiling | Keep current 45 s / 180 s worker defaults and current phone configuration limits; mission deadline always wins |
| Temporary readiness loss | Stop new triggers immediately; 20 s total recovery grace or remaining mission time, whichever is shorter |
| Capture heartbeat | Publish/probe every 2 s; readiness lost after 6 s without fresh camera frames |
| Voice prewarm renewal | At eight minutes of idle prepared-session age; close old session before opening replacement |
| End request | Stop local capture/playback first; best-effort acknowledged server request with 3 s deadline, then disconnect |
| Recorder finalization | Poll once per second for up to 30 s in the worker; durable service reconciliation continues afterward |
| Maximum active mission | 900 s from server readiness commit, never extended |

Measure these values on hardware; do not hide failures by extending the 900-second bound. Before readiness, persist a separate setup expiry so an abandoned starting worker also terminates.

## Task 1: Resolve deployment and prove the voice/recording adapters

**Files:** Create `docs/superpowers/plans/2026-09-06-mission-integration-evidence.md` during execution. No application edits in this task.

**Consumes:** Existing `/livekit-token` contract, requirements, Swift package pin, worker entrypoint.

**Produces:** Verified service repository/path and deployment owner; exact worker package/model versions; selected public voice lifecycle APIs; durable finalization path; contract amendments if needed. This task must pass before Tasks 3–6.

- [ ] Read the actual token service once its location is supplied. Record source path, named dispatch, token metadata forwarding, auth boundary, room creation/rejoin behavior, and how the phone can query mission status. Do not print tokens or environment values.
- [ ] Inspect installed/deployed package metadata and model identifier. Read the matching tagged SDK source rather than treating current upstream documentation as the installed API.
- [ ] Run a throwaway adapter probe only after implementation is authorized: connect once, record once, speak welcome, close only voice session, prepare a clean session, begin three different briefs, and observe room/egress IDs. Record provider connection counts and first-audio timing. No transcript/history deletion assumption is acceptable.
- [ ] Verify server-side input gating does not unsubscribe/mute the published audio used by egress. Ambient speech must remain in MP4 and absent from the voice model's user transcript.
- [ ] Verify session resumption/GoAway handling across ten minutes, plus independent clean-session renewal. Confirm that `generate_reply(instructions=brief)` supplies the current study behavior without reconnecting at trigger time.
- [ ] Choose and record durable integration: worker writes immutable mission objects in the existing recording bucket; authenticated token service reads them and reconciles egress through LiveKit API. The service must support a single active worker generation per mission and atomic replacement fencing. Identify its actual storage mechanism before writing that adapter.
- [ ] Extend this plan with exact external service files and verification commands after ownership is resolved. Do not silently implement the local `gateway/src/server.ts` as if it were deployed.

**Required external behavior:** idempotent create/rejoin keyed by mission ID; reject conflicting owner/study; preserve deadline across replacement; issue a generation-fenced dispatch; authenticated mission-status read; reconcile finalizing recordings after worker exit; perform room cleanup only after recording completion/failure or a documented terminal recovery policy. Token TTL must allow the full mission plus setup/rejoin overhead (proposed 30 minutes); the server still enforces the 900-second mission deadline.

**Gate:** If this service is inaccessible or the model probe fails, report the concrete gap and revise the adapter task before implementation. The pure state/protocol tasks can still be designed/tested independently. No claim of deployment readiness without this evidence.

## Task 2: Pure state machine and cross-language protocol

**Files:** Create `MissionState.swift`, `MissionProtocol.swift`, `agent/corvus_mission_protocol.py`, `agent/tests/test_mission_protocol.py`, `samples/CameraAccess/CameraAccessTests/CorvusMissionStateTests.swift`, and `tests/fixtures/mission-v1.json`.

**Interfaces:**

```swift
enum MissionPhase: String, Codable {
  case idle, starting, welcome, shopping, interviewing, reconnecting, ending
}
struct MissionState {
  private(set) var phase: MissionPhase = .idle
  private(set) var generation: Int = 0
  private(set) var deadline: Date?
  mutating func begin() -> Int
  mutating func ready(generation: Int, deadline: Date)
  mutating func welcomeFinished(generation: Int)
  mutating func beginInterview(generation: Int) -> Bool
  mutating func interviewFinished(generation: Int)
  mutating func loseReadiness(generation: Int)
  mutating func recover(generation: Int, now: Date)
  mutating func end()
  mutating func finishedEnding()
  func expired(at now: Date) -> Bool
}
```

`MissionEnvelope` contains the validated fields above. `MissionSnapshot` contains sequence, phase, serverNowMs, startedAtMs/deadlineMs, activeInterceptId, voiceReady, and recording segments. `MissionBrief` contains the begin payload. `MissionResult` contains ordered timestamped role/text items, trigger metadata, endedBecause/abortReason, and recording references. Define these as Codable Swift structs and validated Python dataclasses with matching JSON keys and shared fixtures.

- [ ] Write the following regression tests before implementation:

```swift
func testLateReadyCannotRestartEndedMission() {
  var state = MissionState()
  let generation = state.begin()
  state.end()
  state.ready(generation: generation, deadline: Date(timeIntervalSince1970: 1900))
  XCTAssertEqual(state.phase, .ending)
}
func testRecoveryKeepsOriginalDeadline() {
  var state = MissionState()
  let generation = state.begin()
  let deadline = Date(timeIntervalSince1970: 1900)
  state.ready(generation: generation, deadline: deadline)
  state.welcomeFinished(generation: generation)
  state.loseReadiness(generation: generation)
  state.recover(generation: generation, now: Date(timeIntervalSince1970: 1800))
  XCTAssertEqual(state.deadline, deadline)
  XCTAssertTrue(state.expired(at: deadline))
}
```

Python validator API: `decode_command(raw: bytes, sender: str, owner: str, mission_id: str) -> dict`. Raise `ValueError` on invalid version/IDs/size/type/ownership. Deduplication API: `OperationLedger.claim(operation_id: str, canonical_payload: bytes) -> bool`, returning true once and false for identical retry, raising `ValueError` on conflict.

```python
import unittest
from corvus_mission_protocol import OperationLedger

class ProtocolTests(unittest.TestCase):
    def test_conflicting_retry_never_becomes_second_operation(self):
        ledger = OperationLedger()
        self.assertTrue(ledger.claim("operation-1", b'{"type":"sync"}'))
        self.assertFalse(ledger.claim("operation-1", b'{"type":"sync"}'))
        with self.assertRaises(ValueError):
            ledger.claim("operation-1", b'{"type":"end_mission"}')
```

Use valid UUIDs in envelope fixture validation; the ledger itself operates on opaque already-validated IDs. Add shared-fixture round-trip tests, unsupported version, foreign sender, oversize payload, expired recovery, duplicate begin, and all-state end cases.

- [ ] Run Python tests with `PYTHONPATH=agent python3 -m unittest discover -s agent/tests -p 'test_mission_protocol.py' -v`; expected initial import failure, then passing assertions after implementation.
- [ ] Implement state guards with generation invalidation:

```swift
mutating func end() {
  generation += 1
  phase = .ending
}
mutating func ready(generation: Int, deadline: Date) {
  guard generation == self.generation, phase == .starting else { return }
  self.deadline = deadline
  phase = .welcome
}
```

`begin()` changes idle to starting once; duplicates return the existing generation. `recover` requires reconnecting and an unexpired existing deadline. Every async completion supplies the generation captured before its await. Use monotonic scheduling for local timers, with a server-time sample and conservative transit allowance; a changed wall clock cannot extend capture.

- [ ] Run XCTest using the existing CameraAccess scheme and an installed iOS simulator selected with `xcodebuild -showdestinations -project samples/CameraAccess/CameraAccess.xcodeproj -scheme CameraAccess`. Save the selected destination and exact invocation in the execution log; do not invent a simulator ID.
- [ ] Commit the independently tested state/protocol change.

## Task 3: Durable mission recordings and results

**Files:** Create `agent/corvus_mission_recording.py`, `agent/corvus_mission_store.py`, `agent/tests/test_mission_recording.py`; modify `agent/requirements.txt` only for the selected storage adapter and pin versions proven in Task 1. External service adapter files must first be supplied by Task 1.

**Interfaces:**

```python
class MissionRecording:
    async def start(self, room_name: str, mission_id: str, segment_id: str) -> dict: raise NotImplementedError
    async def wait_active(self, timeout: float) -> dict: raise NotImplementedError
    async def stop(self) -> None: raise NotImplementedError
    async def reconcile(self) -> dict: raise NotImplementedError

class MissionStore:
    async def put_event(self, mission_id: str, event_id: str, event: dict) -> None: raise NotImplementedError
    async def put_result(self, mission_id: str, intercept_id: str, result: dict) -> str: raise NotImplementedError
    async def read_snapshot(self, mission_id: str) -> dict: raise NotImplementedError
```

These abstract adapter contracts deliberately fail until implemented; they are not production implementations. Implement methods using the proven LiveKit and object-storage adapters. Inject those adapters into constructors for tests. `put_event` and `put_result` are idempotent writes: duplicate identical content succeeds; a conflicting immutable key fails.

Paths: `hack/missions/<missionId>/segments/<segmentId>.mp4`, `hack/missions/<missionId>/events/<eventId>.json`, `hack/missions/<missionId>/intercepts/<interceptId>.json`. Never use a display name as an object key. The service owns the mutable generation lease; worker event/result objects are immutable and include that generation. Terminal states cannot be overwritten by stale-generation writes.

- [ ] Add a fake egress client and fake object store with deterministic responses. Test these sequences:

```python
async def assert_not_saved_until_complete(recording, fake_egress):
    await recording.stop()
    fake_egress.status = "EGRESS_ENDING"
    assert (await recording.reconcile())["status"] == "finalizing"
    fake_egress.status = "EGRESS_COMPLETE"
    assert (await recording.reconcile())["status"] == "saved"
```

Put this helper in `test_mission_recording.py`; call it from `unittest.IsolatedAsyncioTestCase` using a fake client passed to `MissionRecording`. Also assert missing credentials/start failure prevents readiness, stop is idempotent, storage failure prevents an acknowledged durable result, and recorder failure remains visible after room closure.

- [ ] Run `PYTHONPATH=agent python3 -m unittest discover -s agent/tests -p 'test_mission_recording.py' -v` and confirm initial missing behavior.
- [ ] Extract existing egress configuration into the mission adapter while leaving legacy behavior intact. Keep grid/portrait and initially use the proven preset; validate 24fps custom encoding in the hardware task before changing it. Persist recording key/egress ID as soon as returned, then wait for active status. Read recorder timestamps from egress; do not use phone trigger receipt as recording time zero.
- [ ] On end, stop egress, persist finalizing, poll with the bound above, and hand remaining reconciliation to the durable service. Only verified COMPLETE with file results yields saved. FAILED/ABORTED/LIMIT_REACHED yields a terminal recording failure with reason and any recoverable file metadata.
- [ ] Implement authenticated mission-status/result reads in the actual token service after Task 1 supplies its files. On replacement, service reconciles and fences the previous worker/recorder before minting a new generation; if exclusivity cannot be established, end/recover visibly instead of spawning competing recordings.
- [ ] Run fake failure tests and a real recording finalization test where the phone disconnects before the file completes. Commit the recording/result lifecycle change.

## Task 4: Persistent worker and clean voice preparation

**Files:** Create `agent/corvus_mission.py`, `agent/corvus_mission_voice.py`, `agent/tests/test_mission.py`, `agent/tests/test_mission_voice.py`; modify `agent/main.py`, `agent/Dockerfile`.

**Interfaces:**

```python
class MissionVoice:
    async def prepare(self) -> None: raise NotImplementedError
    async def greet(self, text: str) -> None: raise NotImplementedError
    async def interview(self, brief: dict, intercept_id: str) -> dict: raise NotImplementedError
    async def interrupt(self, reason: str) -> None: raise NotImplementedError
    async def close(self) -> None: raise NotImplementedError

class MissionSession:
    async def run(self) -> None: raise NotImplementedError
    async def handle(self, envelope: dict, sender: str) -> dict: raise NotImplementedError
    async def end(self, reason: str) -> None: raise NotImplementedError
```

Inject room control, clock, voice, recording, store, and command/event adapters into `MissionSession`; do not bury room deletion in `MissionVoice`. Define transport-neutral fakes in `agent/tests/mission_fakes.py` with `FakeClock.advance(seconds)`, `FakeRoom.delete_calls`, `FakeVoice.prepare_calls`, `FakeVoice.interview_calls`, `FakeRecording.start_calls`, and an in-memory `MissionStore` implementation.

- [ ] Write async regression tests: three sequential interviews keep `delete_calls == 0` and `start_calls == 1`; duplicate begin produces one `interview_calls` entry; ambient input is disabled during shopping; late greeting/model completion after end cannot publish speech; mission deadline beats interview ceiling; quiet shopping does not run the 45-second interview silence timer.
- [ ] Run `PYTHONPATH=agent python3 -m unittest discover -s agent/tests -p 'test_mission*.py' -v` before implementation and observe targeted missing behavior.
- [ ] Add explicit mode dispatch before the ordinary assistant setup:

```python
corvus = meta.get("corvus") or {}
if corvus.get("mode") == "mission":
    # Validate v1 and ownership before constructing MissionSession.
    await run_mission(ctx, participant, corvus, engine)
    return
```

Define `async def run_mission(ctx, participant, metadata: dict, engine: str) -> None` in `corvus_mission.py`. It validates the signed mission/generation metadata, constructs adapters, and calls `MissionSession.run()`. Malformed mission metadata fails explicitly. Legacy `mode=intercept` continues into the current path. Do not remove the configured agent name.

- [ ] Prepare audio while recording starts; wait for client/media readiness and active recorder. Commit startedAt/deadline to durable state before the welcome. Bound total setup at 45 seconds. On failure close voice, stop capture/recording, persist partial metadata, and clean up.
- [ ] Implement voice lifecycle using Task 1's verified session APIs. Start with audio input disabled and output ready. Wait for actual welcome playout completion; prepare a clean silent voice session afterward. During a begin request, enter interviewing under one async lock before starting speech, use the current device brief, collect only timestamped conversation items belonging to that interview generation, and wait for actual playout completion before normal finish.
- [ ] On `end_intercept`, finalize only the interview and disable model input. Persist its result before announcing completion. Prepare a fresh voice session during cooldown. Do not delete context in place on Gemini; do not reuse its resumption handle for a different interview. Stable mission policy must prohibit speech without the explicit greeting/begin signal; enforce output gating as well as prompting.
- [ ] Reuse silence/ceiling values but start/stop listeners per interview. Keep immutable ordered role/text events as the authoritative source; preserve them alongside the existing question/answer rendering. Stop/cancel output on timeout, collect available items, and mark partial results accurately.
- [ ] Implement original deadline enforcement, transient disconnect grace, fresh-frame heartbeat, quiet-session renewal, and terminal cleanup. Client loss must not cause immediate framework room deletion; preserve server cleanup ownership and close only the necessary voice session. If SDK defaults cannot be configured for this, Task 1 fails rather than silently weakening cleanup.
- [ ] Include all new modules in Dockerfile COPY. Run tests plus container build when implementation is authorized. Commit worker lifecycle independently of iOS UI.

## Task 5: iOS transport, mission ownership, and watcher cancellation

**Files:** Create `MissionTransport.swift`, `MissionCoordinator.swift`, and `MissionStore.swift` in the Corvus directory; create `CorvusMissionCoordinatorTests.swift` and `CorvusMissionTransportTests.swift` in `samples/CameraAccess/CameraAccessTests/`; modify `OpenClaw/LiveKitSession.swift`, `Corvus/WatcherCoordinator.swift`, `Corvus/TriggerStateMachine.swift`, `Corvus/LiveKitInterceptor.swift`, `Corvus/Interceptor.swift`, `Corvus/CorvusLog.swift`.

**Interfaces:**

```swift
@MainActor protocol MissionTransport: AnyObject {
  func connect(missionID: UUID, configuration: MissionConfiguration) async throws
  func request(_ command: MissionEnvelope) async throws -> MissionEnvelope
  func disconnect() async
}
@MainActor protocol MissionCapture: AnyObject {
  func start(configuration: MissionConfiguration) async throws
  func stop() async
}
@MainActor final class MissionCoordinator: ObservableObject {
  func start(configuration: MissionConfiguration) async
  func end(reason: String) async
  func conduct(_ trigger: Trigger, study: Study) async -> InterceptRecord
  func receive(_ snapshot: MissionSnapshot) async
}
```

Implement the concrete transport as `LiveKitMissionTransport` in `MissionTransport.swift`. `MissionConfiguration` snapshots `Study`, existing `CaptureSource`, and existing `IntelligenceEngine` at Start; persistent setting changes cannot mutate this value. Inject transport, capture, store, and a clock into the coordinator. Expose published `phase`, `recordingStatus`, and `errorMessage`; deadline remains internal.

`MissionStore` writes under `CorvusLog.shared.sessionDirectory/missions/<missionId>/manifest.json` and preserves existing per-interview output. Use `.atomic` writes and propagate errors before ACK. Add optional mission ID and segment/offset references to `InterceptRecord` so old records still decode.

- [ ] Add fake transport/capture and deterministic clocks. Test End while ticket fetch is suspended, stale camera-ready callback, late completed transcript, recover at/after deadline, identical event replay, cancellation during accepted interview, and rejected begin releasing the watcher lock exactly once.
- [ ] Make the late-connect test assert actual cleanup, not just UI state:

```swift
// Fixture exposes a suspended connection completion.
await fixture.startUntilConnectIsPending()
await fixture.coordinator.end(reason: "user_ended")
fixture.transport.completePendingConnect()
await fixture.drain()
XCTAssertFalse(fixture.capture.isRunning)
XCTAssertFalse(fixture.transport.isConnected)
XCTAssertEqual(fixture.voicePlaybackCountAfterEnd, 0)
```

Implement these fixture methods in `CorvusMissionCoordinatorTests.swift` using continuations and injected adapters; `drain()` awaits tracked tasks rather than sleeping. The fixture playback counter increments only for post-end events accepted by the coordinator.

- [ ] Register event handlers once before room connect; retain valid sender/mission/generation checks. Decode complete streams with byte limits. Apply retry timings above, preserve operation IDs, and sync after ambiguity rather than replaying a begin with a fresh ID. Never subscribe controls as model user text.
- [ ] Refactor connection input into an explicit frozen configuration for mission mode. Add `stop(restartPreview: Bool = true)` to `LiveKitSession`, preserving existing callers; mission teardown uses false and explicitly stops/unpublishes microphone/video, grabber, phone preview, and DAT capture. Add generation checks after every connection/capture await and dispose resources created by a stale completion.
- [ ] Implement `MissionCoordinator.conduct` using a preexisting room and accepted begin. Await a correlated result, not agent departure. On cancel request `cancel_intercept` unless the entire mission is ending. Legacy `LiveKitInterceptor` retains its standalone implementation; when injected with a mission coordinator it delegates to `conduct` instead.
- [ ] Add `WatcherCoordinator.setMissionReady(_ ready: Bool)` and a generation guard for in-flight detection/interview work. It gates observations/triggers without calling `start()` on every readiness change, because `start()` resets cooldowns. On readiness loss clear only accumulating evidence, preserve earned cooldown timestamps, and cancel/discard in-flight detection. Extend `TriggerStateMachine` with an explicit evidence-clear operation if needed, and add regression tests to `CorvusTriggerTests.swift` proving cooldown survives reconnect while stale held-product evidence does not.
- [ ] Track the watcher's interview Task and generation so an old result can be persisted without releasing a new mission's lock or applying cooldown to its machine. Use unique IDs to store late results once.
- [ ] Reconcile durable server results/recording state on reconnect and when returning to the app. Derive offsets from server/egress timestamps with explicit gap markers; never substitute phone receipt time for actual speech time.
- [ ] Run targeted XCTest suites and existing trigger tests. Commit orchestration/transport changes.

## Task 6: Mission front door and capture lifecycle

**Files:** Create `MissionControls.swift`; modify `Views/StreamSessionView.swift`, `ViewModels/StreamSessionViewModel.swift`, `OpenClaw/LiveKitStreamView.swift`, `Corvus/CorvusConfig.swift`; add `CorvusMissionPresentationTests.swift`.

**Consumes:** Coordinator published phase/recordingStatus/errorMessage; `start(configuration:)` and `end(reason:)`.

**Produces:** Participant-facing mission controls, no lifecycle-driven automatic mission, no timer/warning.

- [ ] Test presentation mapping for idle/start/active/reconnecting/ending/error. Define `MissionPresentation` in `MissionControls.swift` with `primaryTitle`, `statusText`, `canStart`, and `canEnd` computed from phase and recording status. It contains no time or deadline input.

```swift
func testShoppingPresentationHasOnlyMissionStatus() {
  let view = MissionPresentation(phase: .shopping, recordingStatus: .recording)
  XCTAssertEqual(view.statusText, "Mission active · Recording")
  XCTAssertTrue(view.canEnd)
  XCTAssertFalse(view.canStart)
}
```

Define `RecordingStatus` in `MissionProtocol.swift` as starting, recording, finalizing, saved, failed. A nil recording status represents no recorder yet.

- [ ] Mount the coordinator above source-specific child views so camera source/UI replacement cannot destroy ownership. Replace automatic watcher/room startup with Start Mission for the participant flow. Pairing remains a separate prerequisite; initial UI does not start product detection. Restrict auto-resume tasks to the current active mission generation.
- [ ] Wire the primary button to `Task { await coordinator.start(configuration: frozenConfiguration) }`; End uses `Task { await coordinator.end(reason: "user_ended") }`. `frozenConfiguration` is constructed from selected study/source/engine at the click and stored by the coordinator, not reread after awaits.
- [ ] Route the existing call/hangup control through mission actions during a mission. Disable source/interceptor/engine changes for the active mission or label settings as applying to the next mission; remove current onChange redial in mission mode. Ordinary assistant mode keeps its current behavior.
- [ ] Remove `.onDisappear { watcher.stop() }` ownership from the active mission path; settings/navigation alone must not end a mission. Background/lock handling preserves only supported capture behavior and reports lost readiness. End must cancel glasses auto-start/resume, stop DAT, and leave no preview restarted.
- [ ] Show Start Mission, Starting mission…, Mission active/Interviewing/Reconnecting, recording state, and End Mission. No remaining-time label, timer progress ring, or one-minute announcement. After the deadline use ordinary ended/finalizing/saved state with the technical reason only in logs/results.
- [ ] Run presentation tests and inspect the UI on simulator for all states. Commit UI integration.

## Task 7: Hardware validation, fault recovery, and documentation

**Files:** Update `docs/realtime.md`, `docs/architecture.md`, `docs/output.md`; create `docs/superpowers/plans/2026-09-06-mission-validation.md` during execution. Add regression tests to the relevant existing task suites when a fault is found. All tests and probes in this plan are future validation; only document consistency checks have run during planning.

- [ ] Run all mission Python tests and iOS mission/trigger tests once the final changes are integrated. Run the gateway's own checks only if the actual service changes are in this repo; otherwise record the verified external checks from Task 1. Build the worker container and iOS app. Do not deploy as an incidental part of testing.
- [ ] With authorized test infrastructure and hardware, record a full 15-minute glasses mission: greeting, three distinct product interviews, several quiet minutes, a provider connection crossing ten minutes, and a final interview overlapping the deadline. Verify one room and egress for the healthy run, audio routing, first greeting recorded, no ambient responses, clean interview transcripts, and no timer/warning.
- [ ] Repeat bounded fault scenarios: End during ticket fetch, welcome, conversation, reconnect, and recorder startup; phone lock/unlock; incoming call; glasses fold/disconnect; brief network loss; worker failure; recorder failure; lost acknowledgment; app exit during recording finalization. End must prevent delayed restart in every scenario.
- [ ] Verify expected outcomes in saved artifacts: original deadline survives recovery; replacement recordings share mission ID with explicit gaps; no duplicate interview; terminal recording status remains recoverable without the original phone connection. Confirm both successful and failed recording completion paths with fake API events and one real success path.
- [ ] Instrument these timestamps separately: button press, ticket returned, room connected, first camera frame, recorder active, model ready, welcome playout, trigger fired, begin received, first interview audio generated, first interview audio played on phone, interview finished, capture stopped, file complete. Emit IDs and durations, never tokens. Report p50/p95 onset over at least ten eligible triggers plus the full-duration run; the sub-second target is measured, not presumed.
- [ ] Inspect MP4 using `ffprobe`/playback when available: visible camera frames, greeting/audio, actual frame rate, duration, and random interview offsets. Measure size and connection/recording usage. Adopt 24fps encoding only if supported and it preserves footage quality; record the chosen exact bitrate/frame settings.
- [ ] Update docs with Start/End flow, invisible cap, mission manifest layout, full-recording semantics, transcript offsets, recovery gaps, setup/finalization failures, protocol compatibility, and actual endpoint ownership. Preserve legacy mode instructions.
- [ ] Commit documentation and verified fixes; report test results, hardware limitations, and external deployment status. Keep deployment as a separately authorized step.

## Coverage review

| Spec requirement | Tasks |
|---|---|
| Explicit Start/End, all-state cancellation | 2, 5, 6 |
| Camera/agent/recorder readiness before welcome | 1, 3, 4, 5 |
| Warm room, recording, and model at intercept | 1, 4, 5 |
| Quiet model, continuous ambient recording | 1, 4, 7 |
| Separate transcripts and recording offsets | 2, 3, 4, 5, 7 |
| Invisible 900-second deadline; no warning | 2, 4, 5, 6, 7 |
| Durable finalization after phone/worker loss | 1, 3, 7 |
| Duplicate protection, stale triggers, cooldown preservation | 2, 4, 5 |
| Recovery segments, original deadline, no repeated welcome | 1, 3, 4, 5, 7 |
| Glasses background/call interruption behavior | 5, 6, 7 |
| Legacy modes and coordinated protocol rollout | 1, 4, 5, 6 |
| Latency and recording quality evidence | 1, 7 |

## Execution handoff

The user approved the design and requested planning before code. Implementation is not started. Before execution, resolve Task 1's token-service location and confirm the adapter evidence. Execution can then proceed inline using executing-plans or, if the user chooses, with subagent-driven-development. No automatic subagent dispatch or deployment is authorized by this document.
