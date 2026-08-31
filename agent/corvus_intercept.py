"""Corvus's intercept, kept out of upstream's agent.

`main.py` belongs to VisionClaw and is pulled from `upstream`. Everything
specific to Corvus lives here so that file keeps a hook rather than a hundred
lines of intercept logic -- the same split the iOS app uses, where Corvus owns a
directory and touches upstream files only at seams.

The intercept brief arrives in the room token's participant metadata. The
instructions are composed on the phone from the study being run, so this module
never learns what a study is: it receives finished text and runs a conversation
against it.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from datetime import datetime, timezone
from typing import Any

from livekit.agents import JobContext, RunContext, function_tool

logger = logging.getLogger("corvus-intercept")

# The phone listens for the finished transcript on this topic.
TRANSCRIPT_TOPIC = "corvus.transcript"

# Silence before the intercept gives up. A realtime model has no clock: if the
# wearer says nothing it waits indefinitely, and glasses left holding an open
# microphone are worse than a short intercept.
IDLE_EXIT_SECONDS = float(os.environ.get("CORVUS_IDLE_EXIT_SECONDS", "45"))
# Absolute ceiling, in case the model never calls end_intercept.
CEILING_SECONDS = float(os.environ.get("CORVUS_INTERCEPT_CEILING_SECONDS", "180"))

# Glasses recordings live under one prefix in a bucket shared with pulseiq's
# interview recordings.
EGRESS_ROOT = "glasses"
# Characters allowed in the session folder name. It arrives from the phone and
# becomes part of an object key, so it is filtered rather than trusted.
SAFE_SEGMENT = re.compile(r"[^A-Za-z0-9._-]")


def brief_from_metadata(meta: dict[str, Any]) -> dict[str, Any] | None:
    """The intercept brief, or None for an ordinary assistant call."""
    corvus = meta.get("corvus") or {}
    if corvus.get("mode") != "intercept":
        return None
    if not corvus.get("instructions"):
        logger.warning("corvus metadata present but carries no instructions; ignoring")
        return None
    return corvus


class InterceptSession:
    """One intercept: its end signal, its only tool, and its lifecycle."""

    def __init__(self, brief: dict[str, Any]) -> None:
        self.brief = brief
        self.over = asyncio.Event()
        # The definitive transcript. The phone can only see two independent
        # transcription streams and has to guess their interleaving from
        # arrival order, which mis-pairs whenever the next question lands
        # before the previous answer's final text. Here the items arrive
        # already ordered, already complete, and already attributed.
        self.transcript: list[dict[str, str]] = []
        # Set once the recording starts. `egress_id` is what stops it;
        # `recording_key` is what lets the phone find the file afterwards.
        self.egress_id: str | None = None
        self.recording_key: str | None = None

    @property
    def instructions(self) -> str:
        return self.brief["instructions"]

    def tools(self) -> list:
        """Exactly one tool, and it is a control, not a capability.

        An interceptor with search, notes or cards is an assistant, and anything
        it tells a participant changes what they would have said. But it does
        need a way to hang up: the prompt tells it to leave after its closing
        line, and a realtime model has no other means of doing so.
        """
        over = self.over

        @function_tool
        async def end_intercept(ctx: RunContext) -> str:
            """Call this immediately after your closing line, once the intercept is
            over. It hangs up. Do not call it before you have said your closing
            line, and do not say anything after calling it."""
            logger.info("end_intercept called")
            over.set()
            return "Intercept ended."

        return [end_intercept]

    def observe(self, session: Any) -> None:
        """Record each finished conversation item, in order."""

        @session.on("conversation_item_added")
        def _on_item(ev) -> None:
            item = getattr(ev, "item", None)
            role = getattr(item, "role", None)
            text = (getattr(item, "text_content", None) or "").strip()
            # Gemini leaks internal control tokens (e.g. "<ctrl46>") into output
            # transcription around tool calls; an utterance of those is noise.
            text = re.sub(r"<ctrl\d+>", "", text).strip()
            if not text or role not in ("user", "assistant"):
                return
            self.transcript.append({"role": role, "text": text})

    def _recording_key(self, ctx: JobContext) -> str:
        """Where this intercept's MP4 lands.

        `glasses/<session>/<start>.mp4`. The session segment is the phone's own
        log folder name, so a directory pulled off the device and a prefix in
        the bucket carry the same string and join without a lookup table. The
        filename is the moment the recording started, formatted so that sorting
        the prefix by name sorts it by time.
        """
        session = SAFE_SEGMENT.sub("-", self.brief.get("sessionId") or "") or ctx.room.name
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
        return f"{EGRESS_ROOT}/{session}/{stamp}.mp4"

    async def start_egress(self, ctx: JobContext) -> None:
        """Record the room to S3, if the credentials to do so are present.

        Awaited before the first question rather than fired alongside it: the
        request takes about a second to come back, and an intercept that opens
        by speaking would otherwise spend its opening line outside the
        recording. Failure is logged and dropped -- a lost recording is worth
        much less than the intercept it would have cost.
        """
        bucket = os.environ.get("RECORDINGS_S3_BUCKET")
        region = os.environ.get("RECORDINGS_S3_REGION", "us-east-1")
        access_key = os.environ.get("AWS_ACCESS_KEY_ID")
        secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
        if not bucket or not access_key or not secret_key:
            logger.info("no recording credentials; intercept will not be recorded")
            return

        key = self._recording_key(ctx)
        try:
            from livekit.api import LiveKitAPI
            from livekit.protocol.egress import (
                EncodedFileOutput,
                EncodedFileType,
                EncodingOptionsPreset,
                RoomCompositeEgressRequest,
                S3Upload,
            )

            async with LiveKitAPI() as lkapi:
                info = await lkapi.egress.start_room_composite_egress(
                    RoomCompositeEgressRequest(
                        room_name=ctx.room.name,
                        # Grid, not speaker. The glasses feed is the only video
                        # in the room and the interceptor is a voice, so a
                        # layout that follows the speaker would cut away from
                        # the wearer's view to an empty tile every time the
                        # interceptor talks -- losing the footage that is the
                        # reason to record at all.
                        layout="grid",
                        file_outputs=[
                            EncodedFileOutput(
                                file_type=EncodedFileType.MP4,
                                filepath=key,
                                s3=S3Upload(
                                    access_key=access_key,
                                    secret=secret_key,
                                    region=region,
                                    bucket=bucket,
                                ),
                            )
                        ],
                        # Portrait: the glasses stream arrives 720x1280, and
                        # a landscape preset would letter-box it.
                        preset=EncodingOptionsPreset.PORTRAIT_H264_720P_30,
                    )
                )
            self.egress_id = info.egress_id
            self.recording_key = key
            logger.info("recording to %s (egress %s)", key, info.egress_id)
        except Exception:
            logger.exception("could not start recording: key=%s", key)

    async def stop_egress(self) -> None:
        """Stop the recording so it uploads.

        Must run before delete_room. The egress is a room participant and does
        not leave on its own; deleting the room out from under it aborts the
        recording instead of finalising it, and the file is lost.
        """
        if not self.egress_id:
            return
        try:
            from livekit.api import LiveKitAPI
            from livekit.protocol.egress import StopEgressRequest

            async with LiveKitAPI() as lkapi:
                await lkapi.egress.stop_egress(StopEgressRequest(egress_id=self.egress_id))
            logger.info("recording stopped: egress=%s", self.egress_id)
        except Exception:
            logger.exception("could not stop recording: egress=%s", self.egress_id)

    async def _publish_transcript(self, ctx: JobContext) -> None:
        """Send the transcript to the phone while the engine is still alive.

        Ordering matters: delete_room closes the engine, and anything published
        after it fails with "engine is closed" -- the exact race documented in
        pulseiq-live-kit's session-shutdown notes.
        """
        payload = json.dumps({
            "studyId": self.brief.get("studyId"),
            "itemId": self.brief.get("itemId"),
            # Where the recording will land. Sent here because this is the one
            # channel back to the phone, and Corvus has no backend for it to
            # read the answer from later. Null when nothing was recorded.
            "recordingKey": self.recording_key,
            "turns": self.transcript,
        })
        try:
            await ctx.room.local_participant.send_text(payload, topic=TRANSCRIPT_TOPIC)
            logger.info("published transcript: %d item(s)", len(self.transcript))
        except Exception:
            logger.exception("could not publish transcript (%d items)", len(self.transcript))

    async def run(self, ctx: JobContext, session: Any, *, user_id: str) -> None:
        """Open the intercept, hold the room until it ends, then tear it down."""
        self.observe(session)
        await self.start_egress(ctx)
        # The brief carries the study's exact opening question; waiting for the
        # wearer to speak first would leave them wondering if anything happened.
        session.generate_reply(
            instructions="Begin now with your first line, exactly as written."
        )

        silence_task = asyncio.create_task(self._watch_silence(session, user_id))
        try:
            await asyncio.wait_for(self.over.wait(), timeout=CEILING_SECONDS)
            logger.info("intercept finished normally: user=%s", user_id)
        except asyncio.TimeoutError:
            logger.warning(
                "intercept hit the %.0fs ceiling: user=%s", CEILING_SECONDS, user_id
            )
        finally:
            silence_task.cancel()

        await self._publish_transcript(ctx)
        await self.stop_egress()

        # delete_room, not room.disconnect(): disconnecting only removes this
        # worker and leaves the room alive with the phone still in it. Ordering
        # follows pulseiq-live-kit's session-shutdown notes, where this is the
        # proven teardown; ctx.shutdown() is synchronous and must not be awaited.
        try:
            await ctx.delete_room()
        except Exception:
            logger.exception("delete_room failed: room=%s", ctx.room.name)
        ctx.shutdown()

    async def _watch_silence(self, session: Any, user_id: str) -> None:
        """End the intercept after sustained silence from the wearer.

        The clock deliberately survives the agent speaking. Reset it on the
        model's own turns and a re-prompting agent keeps pushing its deadline
        away, so the exit never fires -- the detail that makes pulseiq-live-kit's
        IdleController work.
        """
        silent_since: float | None = None

        def _on_user_state(event) -> None:
            nonlocal silent_since
            new_state = getattr(event, "new_state", None)
            if new_state is None:
                return
            silent_since = None if new_state == "speaking" else time.monotonic()

        session.on("user_state_changed", _on_user_state)

        while not self.over.is_set():
            await asyncio.sleep(1)
            if silent_since and time.monotonic() - silent_since >= IDLE_EXIT_SECONDS:
                logger.info(
                    "intercept ended on %.0fs of silence: user=%s",
                    IDLE_EXIT_SECONDS,
                    user_id,
                )
                self.over.set()
                return
