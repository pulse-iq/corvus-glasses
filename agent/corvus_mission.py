"""Persistent mission orchestration. Boundary adapters keep lifecycle testable."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import datetime, timezone
from uuid import UUID, uuid4

logger = logging.getLogger("corvus-mission")
COMMAND_TOPIC = "corvus.mission.command"


def mission_prefix(started_ms):
    """Object-key prefix for one mission: the moment its worker took it up.

    Folders sort by time and read as dates in a bucket browser. A mission is
    identified by when it happened rather than by UUID; the IDs remain inside
    manifest.json for anything that needs them.
    """
    stamp = datetime.fromtimestamp(started_ms / 1000, timezone.utc)
    return "hack/missions/" + stamp.strftime("%Y-%m-%dT%H-%M-%SZ")

EVENT_TOPIC = "corvus.mission.event"
WELCOME = "Okay, your mission has started. Go about your shopping trip, and I may ask you a few questions along the way."


class MissionSession:
    def __init__(
        self,
        metadata,
        phone,
        voice,
        recording,
        store,
        room,
        send,
        *,
        now=None,
        prefix=None,
    ):
        self.meta = metadata
        self.phone = phone
        self.voice = voice
        self.recording = recording
        self.store = store
        self.room = room
        self.send = send
        self.now = now or (lambda: int(time.time() * 1000))
        self.phase = "starting"
        self.started = None
        self.ended_at = None
        self.sequence = 0
        self.voice_ready = False
        self.camera = False
        self.heartbeat = self.now()
        self.operations = {}
        self.fingerprints = {}
        self.results = {}
        self.active = None
        self.lock = asyncio.Lock()
        self.ended = asyncio.Event()
        self.ready = asyncio.Event()
        self.interview_task = None
        self.start_task = None
        self.prepared_at = self.now()
        self.prefix = prefix or mission_prefix(self.now())

    def snapshot(self):
        return dict(
            sequence=self.sequence,
            phase=self.phase,
            serverNowMs=self.now(),
            startedAtMs=self.started,
            endedAtMs=self.ended_at,
            voiceReady=self.voice_ready,
            recordingStatus=self.recording.status,
            recordingKey=self.recording.key,
            egressId=self.recording.egress_id,
            recordingStartedAtMs=self.recording.started_at,
        )

    async def emit(self, kind, payload, operation=None, intercept=None):
        self.sequence += 1
        ev = dict(
            version=1,
            missionId=self.meta["missionId"],
            segmentId=self.meta["segmentId"],
            operationId=operation or str(uuid4()),
            type=kind,
            sequence=self.sequence,
            payload=payload,
        )
        if intercept:
            ev["interceptId"] = intercept
        try:
            await asyncio.wait_for(self.send(ev), 3)
        except Exception:
            logger.warning("mission event delivery failed", exc_info=True)
        return ev

    async def state(self):
        await self.emit("state", self.snapshot())

    async def persist(self, **extra):
        await self.store.put(
            self.prefix + "/manifest.json",
            dict(
                self.meta,
                **self.snapshot(),
                interviews=list(self.results.values()),
                **extra,
            ),
        )

    async def start(self):
        if self.phase != "starting":
            return
        self.start_task = asyncio.current_task()
        try:
            async with asyncio.timeout(45):
                await self.persist()
                await asyncio.gather(self.voice.prepare(), self.recording.start())
                await self.ready.wait()
                while not self.camera or self.now() - self.heartbeat > 6000:
                    self.ready.clear()
                    await self.ready.wait()
                if self.phase != "starting":
                    return
                self.started = self.now()
                self.phase = "welcome"
                await self.persist()
                await self.state()
                await self.voice.greet(WELCOME)
                if self.phase != "welcome":
                    return
                await self.voice.prepare()
                if self.phase != "welcome":
                    return
                self.voice_ready = True
                self.phase = "shopping"
                await self.persist()
                await self.state()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("mission setup failed")
            await self.end("setup_failed")

    async def handle(self, e, sender):
        op = e.get("operationId")
        iid = e.get("interceptId")

        async def reject(reason):
            return await self.emit("rejected", {"reason": reason}, op, iid)

        if sender != self.phone:
            return await reject("unauthorized_sender")
        if e.get("version") != 1 or any(
            e.get(k) != self.meta[k] for k in ("missionId", "segmentId")
        ):
            return await reject("protocol_mismatch")
        try:
            UUID(op)
        except (ValueError, TypeError, AttributeError):
            return await reject("invalid_operation")
        fingerprint = json.dumps(e, sort_keys=True)
        if op in self.fingerprints and self.fingerprints[op] != fingerprint:
            return await reject("operation_conflict")
        self.fingerprints[op] = fingerprint
        if op in self.operations:
            previous = self.operations[op]
            await self.send(previous)
            return previous
        kind = e.get("type")
        p = e.get("payload") or {}
        if not isinstance(p, dict):
            return await reject("invalid_payload")
        if kind == "begin_intercept":
            async with self.lock:
                if self.phase != "shopping" or not self.voice_ready or not self.camera:
                    return await reject("not_ready")
                try:
                    UUID(iid)
                except (ValueError, TypeError, AttributeError):
                    return await reject("invalid_intercept")
                if iid in self.results:
                    return await reject("intercept_already_completed")
                if not all(
                    isinstance(p.get(k), str) and p[k]
                    for k in (
                        "studyId",
                        "itemId",
                        "itemName",
                        "instructions",
                        "openingQuestion",
                    )
                ):
                    return await reject("invalid_brief")
                if p["studyId"] != self.meta["studyId"]:
                    return await reject("study_mismatch")
                triggered = p.get("triggeredAtMs")
                if (
                    not isinstance(triggered, (int, float))
                    or abs(self.now() - triggered) > 15000
                ):
                    return await reject("stale_trigger")
                self.phase = "interviewing"
                self.voice_ready = False
                self.active = (iid, p)
                response = await self.emit("accepted", {}, op, iid)
                self.operations[op] = response
                if self.phase != "interviewing" or self.active != (iid, p):
                    return response
                self.interview_task = asyncio.create_task(self.interview(iid, p))
                await self.state()
                return response
        if kind not in (
            "client_ready",
            "cancel_intercept",
            "sync",
            "ack",
            "end_mission",
        ):
            return await reject("unknown_command")
        response = await self.emit("accepted", {}, op, iid)
        self.operations[op] = response
        if kind == "client_ready":
            self.heartbeat = self.now()
            self.camera = p.get("cameraReady") is True
            if self.camera:
                self.ready.set()
            else:
                self.ready.clear()
            if not self.camera and self.phase in ("shopping", "interviewing"):
                await self.pause("camera_unavailable")
            elif (
                self.camera
                and self.phase == "reconnecting"
                and not self.active
                and self.voice_ready
            ):
                self.phase = "shopping"
            await self.state()
        elif kind == "sync":
            await self.state()
            for result in self.results.values():
                await self.emit(
                    "intercept_completed",
                    result
                    if len(json.dumps(result).encode()) < 60000
                    else dict(result, turns=[], transcriptOverflow=True),
                    intercept=result["interceptId"],
                )
        elif kind == "cancel_intercept" and self.active and iid == self.active[0]:
            await self.finish_active("cancelled")
        elif kind == "end_mission":
            requested = p.get("reason", "user_ended")
            allowed = {
                "user_ended",
                "setup_failed",
                "camera_timeout",
                "camera_unavailable",
                "recording_failed",
                "voice_failed",
                "health_failed",
                "persistence_failed",
                "worker_unavailable",
                "connection_failed",
                "readiness_failed",
            }
            await self.end(requested if requested in allowed else "user_ended")
        return response

    async def interview(self, iid, brief):
        try:
            result = await self.voice.interview(brief, iid)
            await self.complete(iid, brief, result)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("interview failed")
            try:
                await self.complete(
                    iid,
                    brief,
                    dict(
                        turns=getattr(self.voice, "turns", []),
                        endedBecause="voice_failed",
                        abortReason="voice_failed",
                    ),
                )
            except Exception:
                logger.exception("interview persistence failed")
                await self.end("persistence_failed")
                return
        if self.phase not in ("ending", "ended"):
            try:
                await self.voice.prepare()
                self.voice_ready = True
                self.phase = "shopping" if self.camera else "reconnecting"
                await self.state()
            except Exception:
                await self.end("voice_failed")

    async def complete(self, iid, brief, result):
        if iid in self.results:
            return
        record = dict(
            brief,
            **result,
            interceptId=iid,
            missionId=self.meta["missionId"],
            segmentId=self.meta["segmentId"],
            endedAtMs=self.ended_at if self.ended_at is not None else self.now(),
            recordingKey=self.recording.key,
            recordingStartedAtMs=self.recording.started_at,
            recordingStatus=self.recording.status,
        )
        # The manifest is the only JSON the mission writes; each interview is
        # carried inline in its `interviews` list rather than as its own object.
        self.results[iid] = record
        self.active = None
        await self.persist()
        inline = (
            record
            if len(json.dumps(record).encode()) < 60000
            else dict(record, turns=[], transcriptOverflow=True)
        )
        await self.emit("intercept_completed", inline, intercept=iid)

    async def finish_active(self, reason):
        active = self.active
        if self.interview_task and self.interview_task is not asyncio.current_task():
            self.interview_task.cancel()
            await asyncio.gather(self.interview_task, return_exceptions=True)
        try:
            await self.voice.interrupt(reason)
        except Exception:
            logger.exception("voice interruption failed; preserving partial result")
        if active:
            await self.complete(
                *active,
                dict(
                    turns=list(getattr(self.voice, "turns", [])),
                    endedBecause=reason,
                    abortReason=reason,
                ),
            )
        if self.phase not in ("ending", "ended"):
            await self.voice.prepare()
            if self.phase in ("ending", "ended"):
                return
            self.voice_ready = True
            self.phase = "shopping" if self.camera else "reconnecting"
            await self.state()

    async def pause(self, reason):
        self.camera = False
        self.phase = "reconnecting"
        if self.active:
            await self.finish_active(reason)
        await self.state()

    async def tick(self):
        if self.phase in ("ending", "ended"):
            return
        # No mission time limit: a trip lasts as long as it lasts. The phone's
        # heartbeat is the safety net for a mission nobody is attending.
        if self.now() - self.heartbeat > 30000:
            await self.end("camera_timeout")
            return
        if (
            self.started
            and self.now() - self.heartbeat > 6000
            and self.phase in ("shopping", "interviewing")
        ):
            await self.pause("camera_unavailable")
        if self.started and not getattr(self.voice, "healthy", True):
            await self.end("voice_failed")
            return
        if self.started:
            async with asyncio.timeout(5):
                status = await self.recording.check()
            if status != "recording":
                await self.end("recording_failed")
        if self.phase == "shopping" and self.now() - self.prepared_at > 240000:
            self.phase = "reconnecting"
            self.voice_ready = False
            await self.state()
            await asyncio.wait_for(self.voice.prepare(), 20)
            if self.phase not in ("ending", "ended"):
                self.prepared_at = self.now()
                self.voice_ready = True
                self.phase = "shopping" if self.camera else "reconnecting"
                await self.state()

    async def end(self, reason):
        if self.phase in ("ending", "ended"):
            return
        self.phase = "ending"
        self.ended_at = self.now()
        self.voice_ready = False
        if (
            self.start_task
            and self.start_task is not asyncio.current_task()
            and not self.start_task.done()
        ):
            self.start_task.cancel()
            await asyncio.gather(self.start_task, return_exceptions=True)
        self.recording.status = (
            "finalizing" if self.recording.egress_id else self.recording.status
        )
        # Stop capture concurrently with transcript/storage flushing at the hard cap.
        recording_stop = asyncio.create_task(self.recording.stop())
        try:
            await self.finish_active(reason)
            await self.persist(endedBecause=reason)
            await self.state()
        except Exception:
            logger.exception("partial mission persistence failed")
        try:
            await self.voice.close()
        except Exception:
            logger.exception("voice close failed")
        try:
            await self.persist(endedBecause=reason)
        except Exception:
            logger.exception("finalization intent persistence failed")
        try:
            await recording_stop
        except Exception:
            self.recording.status = "finalizing"
            logger.exception("recording finalization pending; gateway must reconcile")
        self.phase = "ended"
        try:
            await self.persist(endedBecause=reason)
            await self.emit("recording", self.snapshot())
            await self.emit("mission_ended", dict(self.snapshot(), endedBecause=reason))
        except Exception:
            logger.exception("final mission persistence failed")
        finally:
            try:
                if self.recording.status != "finalizing":
                    await self.room.delete()
            finally:
                self.ended.set()


async def run_mission(ctx, participant, metadata, engine, model_factory):
    """Runtime seam. The signed phone metadata binds this worker to one mission."""
    for field in ("missionId", "segmentId"):
        UUID(metadata[field])
    if metadata.get("version") != 1:
        raise ValueError("unsupported mission protocol version")
    if metadata.get("phoneIdentity", participant.identity) != participant.identity:
        raise ValueError("mission owner mismatch")
    from corvus_mission_storage import MissionRecording, MissionStore
    from corvus_mission_voice import MissionVoice

    class Room:
        async def delete(self):
            try:
                await asyncio.wait_for(ctx.delete_room(), 5)
            finally:
                ctx.shutdown()

    async def send(event):
        await ctx.room.local_participant.send_text(
            json.dumps(event),
            topic=EVENT_TOPIC,
            destination_identities=[participant.identity],
        )

    # One prefix for the recording and the manifest, fixed at the moment the
    # worker takes up the mission, so the two cannot land in different folders.
    prefix = mission_prefix(int(time.time() * 1000))
    mission = MissionSession(
        metadata,
        participant.identity,
        MissionVoice(ctx.room, participant.identity, model_factory),
        MissionRecording(ctx.room.name, prefix),
        MissionStore(),
        Room(),
        send,
        prefix=prefix,
    )
    mission.recording.on_started = mission.persist
    tasks = set()

    async def read(reader, identity):
        try:
            text = await asyncio.wait_for(reader.read_all(), 5)
            if len(text.encode()) <= 65536:
                await mission.handle(json.loads(text), identity)
        except Exception:
            logger.exception("invalid mission command")

    def command(reader, identity):
        task = asyncio.create_task(read(reader, identity))
        tasks.add(task)
        task.add_done_callback(tasks.discard)

    def room_metadata_changed(old_metadata, metadata):
        try:
            corvus = json.loads(metadata or "{}").get("corvus", {})
            if (
                corvus.get("missionId") == mission.meta["missionId"]
                and corvus.get("missionEndRequested") is True
            ):
                task = asyncio.create_task(
                    mission.end(corvus.get("missionEndReason") or "user_ended")
                )
                tasks.add(task)
                task.add_done_callback(tasks.discard)
        except (ValueError, TypeError):
            logger.warning("invalid room mission metadata")

    ctx.room.on("room_metadata_changed", room_metadata_changed)
    room_metadata_changed(None, ctx.room.metadata)
    ctx.room.register_text_stream_handler(COMMAND_TOPIC, command)
    start = asyncio.create_task(mission.start())
    try:
        while not mission.ended.is_set():
            await asyncio.sleep(1)
            try:
                await mission.tick()
            except Exception:
                logger.exception("mission health failure")
                await mission.end("health_failed")
    finally:
        if not mission.ended.is_set():
            await mission.end("worker_shutdown")
        start.cancel()
        for task in tasks:
            task.cancel()
        await asyncio.gather(start, *tasks, return_exceptions=True)
        ctx.room.off("room_metadata_changed", room_metadata_changed)
        ctx.room.unregister_text_stream_handler(COMMAND_TOPIC)
        ctx.shutdown()
