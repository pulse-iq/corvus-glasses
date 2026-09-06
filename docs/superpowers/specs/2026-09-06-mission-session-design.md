# Persistent shopping mission design

Date: 2026-09-06
Branch: `codex/mission-session-prototype`
Status: Agreed design captured for review; application implementation has not started.

## Objective

Move room connection, voice-agent preparation, and recording startup out of the product-intercept path. A shopper explicitly starts a mission, receives a spoken welcome, and completes several short interviews in one persistent LiveKit room.

## Agreed scope

- iOS Corvus prototype; Android remains the upstream sample.
- Button-only Start Mission and End Mission. No spoken activation.
- One room and a prepared voice agent for the mission, with recovery when necessary.
- Record the entire active mission: camera video, shopper/ambient audio, and agent speech.
- Hard maximum mission duration of 15 minutes (900 seconds).
- Preserve existing product detection, study prompts, interview limits, and cooldown rules.
- Keep individual interview transcripts and link them to offsets in the mission recording.
- No application code or deployment until the planning phase is complete and implementation is authorized.

## Shopper experience and states

`Idle → Starting → Welcome → Shopping ⇄ Interviewing → Ending → Idle`

`Reconnecting` temporarily replaces an active state when transport or agent readiness is lost. Unrecoverable failure ends the mission with its partial results retained.

### Idle and Starting

The front door shows the selected study, capture source, and Start Mission. Detection cannot initiate interviews before a mission starts. Existing glasses pairing and permission setup remain available.

Start Mission immediately begins room connection, camera preparation, and agent preparation. Show “Starting mission…” and prevent duplicate starts. End Mission remains available to cancel setup. A failed setup must release resources and offer a retry rather than claim the mission is active.

Start one room-composite recording during setup. Readiness requires usable camera frames, a ready agent, and an active recorder, rather than merely a connected room or an accepted recording request. Recorder startup failure is visible and prevents declaring a fully recorded mission ready; retry or cancel is available. This replaces the existing intercept path's silent unrecorded fallback for mission mode.

### Welcome and mission clock

Once all readiness conditions are met, persist the mission start and deadline and deliver the welcome:

“Okay, your mission has started. Go about your shopping trip, and I may ask you a few questions along the way.”

The 900-second clock starts at this readiness transition and includes the welcome. The recorder may contain a short setup lead-in, so recording start and mission start are separate timestamps. An active recorder status reduces the risk of missing the welcome; confirm first audible/video content in actual recorded output during validation.

Enable interviews after the greeting finishes. Do not queue detections from setup or the greeting for later playback.

### Shopping and Interviewing

Show a recording indicator, remaining mission time, current state, and a persistent End Mission button. Keep the room, published microphone/video, and voice-agent infrastructure alive.

Between interviews, disable audio ingestion into the voice model while continuing microphone publication to the room recorder. Prevent unsolicited model speech and avoid accumulating ambient conversation in model context. Continue the existing local watcher pipeline. Do not stream mission video into the voice model; current code already avoids that because of context exhaustion.

For an eligible trigger, send an interview brief over the established room. The phone continues composing study instructions. Enable agent conversation input and begin the interview after acceptance. Permit only one interview at a time.

`end_intercept` ends the interview, publishes its result, disables conversational input, and returns to Shopping. It does not stop recording, disconnect the worker, or delete the room. Reset interview-specific transcript, model context, callbacks, and timers before the next interview without reintroducing routine model startup on the trigger path. The precise context-reset mechanism must be verified against the deployed model and SDK during implementation planning.

### End Mission and time limit

At 14 minutes, display a one-minute warning without speaking over an interview. At 15 minutes, stop detection and interview audio even mid-interview and mark any interrupted interview with reason `mission_time_limit`. No grace period extends active capture.

The worker enforces the authoritative deadline; the phone independently updates the countdown and stops local capture at the deadline. Reconnects do not reset it. This bounds capture even if the app is suspended or the network fails.

End Mission works during setup, welcome, shopping, an interview, and reconnecting. Immediately stop detection, local media capture/publication, and further agent speech. Invalidate outstanding start/reconnect work so a late completion cannot revive the mission. Preserve partial interview data with an explicit end reason.

Finalize recording before server-side room deletion. Capture ends promptly; file upload/finalization may continue afterward. Distinguish mission ended, recording finalizing, recording saved, and recording failed. Verify successful egress completion rather than interpreting an accepted stop request as a saved file. Cleanup must have bounded waits and retain enough server-side state to finish or report failure if the phone leaves.

## Ownership and components

### iOS mission coordinator

A Corvus-owned coordinator owns mission identity, state, deadline, readiness, cancellation, room lifetime, and recovery. SwiftUI appearance/disappearance must not implicitly start or end a mission. Existing source/model/study switches must not silently redial or reconfigure an active mission; changes take effect on the next mission.

Integrate at these existing seams:

- `samples/CameraAccess/CameraAccess/Views/StreamSessionView.swift`: replace watcher/call auto-start ownership with mission controls and state.
- `samples/CameraAccess/CameraAccess/OpenClaw/LiveKitSession.swift`: retain media transport, add mission control transport/readiness, and distinguish preview, publication, and full capture shutdown. Its current `stop()` restarts a preview, so it is insufficient as End Mission cleanup by itself.
- `samples/CameraAccess/CameraAccess/Corvus/LiveKitInterceptor.swift`: conduct an interview within an existing mission instead of calling room start/stop or waiting for agent departure.
- `samples/CameraAccess/CameraAccess/Corvus/WatcherCoordinator.swift`: gate interviews on mission readiness and preserve current locking/cooldowns.
- `samples/CameraAccess/CameraAccess/Corvus/Interceptor.swift`: extend persisted results with mission, recording-segment, and offset references as needed.

Keep Corvus-specific behavior in Corvus modules, with small seams in upstream-owned files. Preserve existing non-mission modes for development rather than silently changing their contracts.

### Mission worker

Add a mission lifecycle alongside the existing one-interview lifecycle in `agent/corvus_intercept.py`, with dispatch integration in `agent/main.py`. A new module, if used, must also be included in `agent/Dockerfile`.

The worker owns greeting, quiet waiting, interview acceptance/completion, authoritative results, recording lifecycle, deadline enforcement, and server cleanup. Interview silence/ceiling timers apply only to an interview; they must not terminate a quiet shopping mission. Remove per-interview listeners and tasks when each interview ends.

Retain explicit named worker dispatch. Unknown or unsupported mission protocol versions must fail visibly instead of falling through to the generic assistant.

### Control contract

Define a versioned mission mode and explicit application messages for readiness, begin-interview, acceptance/rejection, interview completion, mission end, recording status, and recovery state synchronization.

Messages carry mission ID, applicable interview ID, and operation ID. Validate sender identity against the room's authorized phone/worker; correlate every response to its mission and interview. Duplicate operations must acknowledge their existing outcome rather than repeat a question or allocate another room/recorder.

Use acknowledged/retryable delivery with bounded timeouts. Retain terminal interview results until acknowledged or recoverably stored. On reconnect, reconcile state before accepting triggers; reliable transport alone is not durable delivery across a replacement room. Reject stale events from prior missions.

Detailed schemas and timeout values belong in the implementation plan after verifying the actual deployed endpoint and SDK versions.

## Recording and data

Use one MP4 per uninterrupted mission room, retaining the existing glasses-focused grid layout. Start recording once and avoid recorder startup on every interview. Target the actual camera frame rate rather than increasing it solely for the recorder; validate output settings before fixing a bitrate budget.

Maintain a mission manifest with identity, study, start/deadline/end timestamps, end reason, recording segments/status, and interview references. Each segment includes its room, egress ID, storage key, recording start/end, and any known gap. Each interview keeps its own authoritative transcript and start/end timestamps, with recording offsets derived from that segment's recording timeline. Exclude the greeting and other interviews from interview transcripts.

A replacement room creates another recording segment under the same mission. Preserve segments and mark gaps; stitching video is outside the prototype scope. Cloud recording cannot reconstruct media lost during an uplink outage.

Persist enough recording/mission metadata outside transient room messages to recover finalization status after phone disconnect or worker failure. Resolve the storage location with the deployed endpoint before implementation; do not leave the only recording reference in a final message to a disconnected phone.

Estimated size at an illustrative combined bitrate of 2–4 Mbps is 225–450 MB for 15 minutes, excluding overhead. This is a sizing estimate, not a measured result or fixed encoder requirement. Full-mission recording increases upload, battery, recording, and storage usage compared with recording interviews alone. Continuous ambient audio is intentional and is represented by the visible recording indicator.

## Recovery and long-running behavior

- Pause interviews when the room, camera, recorder, or voice agent loses readiness. Discard stale triggers instead of asking about a product after reconnect.
- Reconnect within the original mission deadline, synchronize state, and resume only after readiness is verified. Do not repeat the welcome.
- Mark interrupted interviews as interrupted; agent departure or room loss is not normal interview completion.
- If recording fails during a mission, show the failure and stop new interviews while attempting bounded recovery. End with partial results if recording readiness cannot be restored.
- Voice-model connection/session health is distinct from room health. Verify idle timeout and context/session renewal behavior, and prepare replacements during quiet periods when needed. Do not assume a warm room guarantees a warm model.
- An app crash or lost phone connection must not leave a worker recording indefinitely. The worker deadline and disconnect cleanup remain in force.
- Confirm phone lock/background operation, glasses routing, camera continuity, and call interruptions on hardware. These are prototype acceptance requirements, not capabilities established by this design.

## Deployment prerequisite

`docs/realtime.md` describes a Corvus token endpoint that forwards `corvus` metadata and explicitly dispatches a named worker. The checked-in `gateway/src/server.ts` endpoint currently mints metadata containing only `engine` and does not implement that documented dispatch contract.

Before implementation, identify the deployed token service and its source, verify the actual model/SDK versions, and determine where mission metadata and finalization status can be persisted. Do not assume editing the checked-in gateway changes the service used by the app. Phone and worker protocol changes require coordinated rollout or explicit version rejection.

## Implementation sequence

1. Verify deployment ownership and SDK/model behavior; specify the mission protocol, persistence, recording lifecycle, and timeout policy.
2. Build mission state ownership and cancellation semantics, including the shared 900-second deadline.
3. Implement the persistent worker, quiet input gating, recording lifecycle, and successive interview handling.
4. Adapt the existing iOS interceptor/watcher and add Start Mission, recording/countdown state, and End Mission.
5. Implement recovery, recording-status persistence, per-interview offsets, and terminal cleanup.
6. Validate on device and document setup, output format, and limitations.

This sequence describes deliverables, not authorization to implement them. A detailed implementation plan follows review of this spec.

## Acceptance criteria

- Opening the app cannot initiate an interview; duplicate Start presses create one mission.
- Welcome begins only after camera, agent, and recorder readiness; first recorded audio/video is inspected.
- Three interviews complete in the same room and recording, with no repeated greeting or per-interview room creation/recording startup.
- Quiet periods produce no unsolicited speech; ambient audio remains in the recording but outside interview transcripts/model input.
- Each interview has the correct product brief, independent transcript, completion reason, and verified recording offsets.
- A full 15-minute hardware run includes long quiet periods and multiple interviews with the phone locked.
- At the hard deadline, capture and agent speech stop even during an interview or network outage; recovery cannot extend the deadline.
- End Mission during every state releases capture and cancels pending work without reopening a room.
- Duplicate, delayed, and lost control messages cannot cause overlapping/repeated interviews or lost acknowledged results.
- Network/agent/recording failures preserve available data, expose gaps/failures, and cannot be misreported as successful completion.
- Recording saved status follows verified successful finalization, including when the phone disconnects before upload finishes.
- Measure mission-start-to-ready and detection-to-first-audible-question separately. Target sub-second intercept onset on a healthy connection; report actual results rather than claiming zero latency.

## Reference material

- Repository: `docs/realtime.md`, `docs/architecture.md`, `docs/output.md`.
- LiveKit audio input control: https://docs.livekit.io/agents/multimodality/text/
- LiveKit composite recording: https://docs.livekit.io/transport/media/ingress-egress/egress/composite-recording/
- LiveKit egress lifecycle: https://docs.livekit.io/reference/other/egress/api/
