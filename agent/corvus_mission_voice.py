"""A fresh realtime model connection prepared between interviews, never at trigger."""

import asyncio
import re
import time

from livekit.agents import Agent, AgentSession, RunContext, function_tool
from livekit.agents.voice.room_io import RoomOptions


class MissionVoice:
    def __init__(self, room, phone, model_factory):
        self.room = room
        self.phone = phone
        self.model_factory = model_factory
        self.session = None
        self.agent = None
        self.turns = []
        self.over = asyncio.Event()
        self.active = False
        self.last_user = 0
        self.reason = "completed"
        self.closed = False
        self.healthy = True
        self.generation = 0
        self.connection_ready = None
        self.track_baselines = {}
        self.close_event = asyncio.Event()
        self.close_task = None

    async def prepare(self):
        if self.closed:
            return
        self.generation += 1
        generation = self.generation
        if self.session:
            await self._dispose(self.session)
        if self.closed or generation != self.generation:
            return
        self.active = False
        self.turns = []
        self.over = asyncio.Event()

        @function_tool
        async def end_intercept(ctx: RunContext):
            """Call after your closing line. End only this product interview. Say nothing afterward."""
            self.over.set()

        self.agent = Agent(
            instructions="Stay silent until explicitly instructed to greet or conduct an interview. Follow the complete study brief supplied with the begin command as your interview policy. Do not respond to ambient audio.",
            tools=[end_intercept],
        )
        self.session = session = AgentSession(llm=self.model_factory())
        participant = getattr(self.room, "local_participant", None)
        self.track_baselines[session] = (
            set(participant.track_publications) if participant else set()
        )
        ready = asyncio.Event()
        self.connection_ready = ready

        def current():
            return (
                not self.closed
                and generation == self.generation
                and self.session is session
            )

        @session.on("metrics_collected")
        def on_metrics(ev):
            metrics = ev.metrics
            if (
                current()
                and getattr(metrics, "request_id", None) == ""
                and getattr(metrics, "acquire_time", 0) > 0
            ):
                ready.set()

        self.session.input.set_audio_enabled(False)
        self.session.output.set_audio_enabled(False)

        @self.session.on("conversation_item_added")
        def on_item(ev):
            item = ev.item
            text = re.sub(
                r"<ctrl\d+>", "", getattr(item, "text_content", "") or ""
            ).strip()
            if (
                current()
                and self.active
                and item.role in ("user", "assistant")
                and text
            ):
                self.turns.append(
                    dict(role=item.role, text=text, atMs=int(item.created_at * 1000))
                )
                if item.role == "user":
                    self.last_user = time.monotonic()

        @self.session.on("user_state_changed")
        def on_user(ev):
            if current() and self.active and ev.new_state == "speaking":
                self.last_user = time.monotonic()

        @self.session.on("error")
        def on_error(ev):
            if current() and not getattr(ev.error, "recoverable", False):
                self.healthy = False
                self.reason = "voice_failed"
                self.over.set()

        try:
            await session.start(
                agent=self.agent,
                room=self.room,
                room_options=RoomOptions(
                    participant_identity=self.phone,
                    text_input=False,
                    video_input=False,
                    close_on_disconnect=False,
                    delete_room_on_close=False,
                ),
            )
            self.session.input.set_audio_enabled(False)
            self.session.output.set_audio_enabled(False)

            async def all_ready():
                await asyncio.gather(ready.wait(), session.room_io.wait_for_ready())

            ready_task = asyncio.create_task(all_ready())
            close_task = asyncio.create_task(self.close_event.wait())
            try:
                done, _ = await asyncio.wait(
                    [ready_task, close_task],
                    timeout=20,
                    return_when=asyncio.FIRST_COMPLETED,
                )
                if not done:
                    raise TimeoutError("Voice or room audio readiness timed out")
                if ready_task in done:
                    await ready_task
            finally:
                for task in (ready_task, close_task):
                    if not task.done():
                        task.cancel()
                await asyncio.gather(ready_task, close_task, return_exceptions=True)
            if not current():
                await self._dispose(session)
                return
        except BaseException:
            await asyncio.wait_for(self._dispose(session), 5)
            raise

    async def greet(self, text):
        if self.closed:
            return
        self.session.output.set_audio_enabled(True)
        try:
            speech = self.session.generate_reply(
                user_input="Please greet the shopper now. Say exactly: " + text,
            )
            await speech.wait_for_playout()
            if error := speech.exception():
                raise RuntimeError("Welcome speech generation failed") from error
            if not any(
                getattr(item, "role", None) == "assistant"
                and (getattr(item, "text_content", None) or "").strip()
                for item in speech.chat_items
            ):
                raise RuntimeError("Welcome produced no assistant speech")
        finally:
            self.session.output.set_audio_enabled(False)

    async def interview(self, brief, iid):
        if self.closed:
            return dict(
                turns=[], endedBecause="mission_ended", abortReason="mission_ended"
            )
        self.active = True
        self.reason = "completed"
        self.last_user = time.monotonic()
        self.over.clear()
        self.session.output.set_audio_enabled(True)
        self.session.input.set_audio_enabled(True)
        self.session.generate_reply(
            instructions="Conduct this interview following the complete study brief:\n"
            + brief["instructions"]
            + "\nBegin now. Say this opening question exactly: "
            + brief["openingQuestion"]
        )
        start = time.monotonic()
        try:
            while not self.over.is_set():
                try:
                    await asyncio.wait_for(self.over.wait(), 1)
                except asyncio.TimeoutError:
                    pass
                if time.monotonic() - start >= 180:
                    self.reason = "interview_time_limit"
                    break
                if time.monotonic() - self.last_user >= 45:
                    self.reason = "silence_timeout"
                    break
            if self.reason == "completed":
                current = self.session.current_speech
                if current:
                    await asyncio.wait_for(current.wait_for_playout(), 10)
            else:
                await self.interrupt(self.reason)
            return dict(
                turns=list(self.turns),
                endedBecause=self.reason,
                **({"abortReason": self.reason} if self.reason != "completed" else {}),
            )
        finally:
            self.active = False
            self.session.input.set_audio_enabled(False)
            self.session.output.set_audio_enabled(False)

    async def interrupt(self, reason):
        self.reason = reason
        self.active = False
        if self.session:
            self.session.input.set_audio_enabled(False)
            self.session.output.set_audio_enabled(False)
            await asyncio.wait_for(self.session.interrupt(force=True), 3)
        self.over.set()

    async def close(self):
        if self.close_task is None:
            # Fence pending preparation synchronously before scheduling cleanup.
            self.closed = True
            self.close_event.set()
            self.generation += 1
            if self.connection_ready:
                self.connection_ready.set()
            self.close_task = asyncio.create_task(self._close_session())
        await asyncio.shield(self.close_task)

    async def _close_session(self):
        try:
            await self.interrupt("mission_ended")
        finally:
            if self.session:
                await asyncio.wait_for(self._dispose(self.session), 5)

    async def _dispose(self, session):
        """SDK RoomIO closes AudioSource but leaves its published track behind."""
        session.input.set_audio_enabled(False)
        session.output.set_audio_enabled(False)
        try:
            await session.aclose()
        finally:
            participant = getattr(self.room, "local_participant", None)
            baseline = self.track_baselines.pop(session, None)
            if participant and baseline is not None:
                for sid, publication in list(participant.track_publications.items()):
                    if sid not in baseline and publication.name == "roomio_audio":
                        await participant.unpublish_track(sid)
