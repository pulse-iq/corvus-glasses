"""Generic turn helpers for a LiveKit AgentSession, ported from pulseiq-live-kit.

`IdleController` is that worker's idle.py with the modality plumbing removed
and the timings made parameters; `turn_at` is its transcript timestamp
alignment. Nothing here knows about missions or intercepts, and nothing here
depends on which model is behind the session.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Awaitable, Callable

logger = logging.getLogger("corvus-idle")

SPEAKING = "speaking"
LISTENING = "listening"

# The agent's VAD detects user speech onset ~0.3-0.5 s after it begins in the
# egress recording: audio travels wearer -> WebRTC -> SFU -> agent, then Silero
# needs accumulated frames. The recording captures the raw frames at once, so
# its timeline is ahead; subtract a fixed offset so user turns line up with it.
USER_VAD_OFFSET_S = 0.5


def turn_at(item, role: str) -> float | None:
    """Best playout time for a conversation item, in epoch seconds.

    Prefer ``started_speaking_at`` (first audio frame), fall back to
    ``created_at``. A ``started_speaking_at`` more than 5 s after creation is a
    late callback and is ignored. User turns are pulled earlier by the VAD lag.
    """
    metrics = getattr(item, "metrics", None) or {}
    speaking_at = metrics.get("started_speaking_at") if isinstance(metrics, dict) else None
    created_at = getattr(item, "created_at", None)
    if speaking_at and created_at and speaking_at > created_at + 5.0:
        speaking_at = None
    if speaking_at and role == "user":
        speaking_at -= USER_VAD_OFFSET_S
    return speaking_at or created_at


class IdleController:
    """Two clocks over a session's speaking states.

    The prompt clock measures time since anyone last did anything and fires
    ``prompt_fn`` (a spoken "are you still there?") once it passes
    ``prompt_seconds``; the exit clock measures unbroken user silence since the
    agent last finished speaking and fires ``exit_fn`` at ``exit_seconds``. Both
    run only while the agent is listening and the user is not speaking, and only
    after the agent has spoken once, so a session's construction time never
    counts as silence. ``prompt_fn`` may be None: a realtime model is told to
    handle silence itself, and only the exit clock applies.
    """

    def __init__(
        self,
        session,
        *,
        exit_seconds: float,
        exit_fn: Callable[[], Awaitable[None]],
        prompt_seconds: float | None = None,
        prompt_fn: Callable[[], Awaitable[None]] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._exit_seconds = exit_seconds
        self._exit_fn = exit_fn
        self._prompt_seconds = prompt_seconds if prompt_fn else None
        self._prompt_fn = prompt_fn
        self._clock = clock
        self._agent_state: str | None = None
        self._user_state: str | None = None
        self._ready = False
        self._last_activity = clock()
        self._silent_since: float | None = None
        self._stop = asyncio.Event()
        self._task: asyncio.Task | None = None
        on = getattr(session, "on", None)
        if on is not None:
            on("agent_state_changed")(self._on_agent_state)
            on("user_state_changed")(self._on_user_state)

    @property
    def running(self) -> bool:
        return (
            self._ready
            and self._agent_state == LISTENING
            and self._user_state != SPEAKING
        )

    def _on_agent_state(self, ev) -> None:
        state = getattr(ev, "new_state", None)
        if state is not None:
            self.set_agent_state(state)

    def _on_user_state(self, ev) -> None:
        state = getattr(ev, "new_state", None)
        if state is not None:
            self.set_user_state(state)

    def set_agent_state(self, state: str) -> None:
        prev, self._agent_state = self._agent_state, state
        if prev == SPEAKING and state == LISTENING:
            self._ready = True
            now = self._clock()
            self._last_activity = now
            if self._silent_since is None:
                self._silent_since = now

    def set_user_state(self, state: str) -> None:
        prev, self._user_state = self._user_state, state
        now = self._clock()
        if state == SPEAKING:
            self._last_activity = now
            self._silent_since = None
        elif prev == SPEAKING and state == LISTENING:
            self._last_activity = now
            self._silent_since = now

    def mark_activity(self) -> None:
        now = self._clock()
        self._last_activity = now
        self._silent_since = now

    async def check(self) -> bool:
        """One tick. Returns True once the exit has fired."""
        if not self.running:
            return False
        now = self._clock()
        # Exit takes precedence over the re-prompt at the boundary.
        if self._silent_since is not None and now - self._silent_since >= self._exit_seconds:
            logger.info("idle exit after %.0fs of silence", now - self._silent_since)
            await self._exit_fn()
            self._stop.set()
            return True
        if self._prompt_seconds is not None and now - self._last_activity >= self._prompt_seconds:
            logger.info("idle prompt after %.0fs", now - self._last_activity)
            # Reset here as well as on the speaking->listening edge the prompt
            # produces, so a prompt that fails to play cannot fire every tick.
            self._last_activity = now
            await self._prompt_fn()
        return False

    async def _run(self) -> None:
        while not self._stop.is_set():
            await asyncio.sleep(1)
            if await self.check():
                return

    def start(self) -> None:
        if not self._task:
            self._task = asyncio.create_task(self._run())

    def stop(self) -> None:
        self._stop.set()
        if self._task and not self._task.done():
            self._task.cancel()
