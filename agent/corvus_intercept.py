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

    async def _publish_transcript(self, ctx: JobContext) -> None:
        """Send the transcript to the phone while the engine is still alive.

        Ordering matters: delete_room closes the engine, and anything published
        after it fails with "engine is closed" -- the exact race documented in
        pulseiq-live-kit's session-shutdown notes.
        """
        payload = json.dumps({
            "studyId": self.brief.get("studyId"),
            "itemId": self.brief.get("itemId"),
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
