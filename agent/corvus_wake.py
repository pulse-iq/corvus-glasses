""""Hey Corvus": the wearer can start a conversation at any time during a mission.

Proof of concept. Nothing here is a wake-word engine. During the shopping
phase a second, mute `AgentSession` listens to the phone's microphone with the
same recognition stack the turn-based mode uses -- Deepgram, Silero and the
multilingual turn detector -- and no language model behind it. Each time the
turn detector closes a user turn, the SDK hands the transcript to
`WakeAgent.on_user_turn_completed`, a small text model is asked whether the
wearer was addressing Corvus by name, and if so the mission is told. The
mission then runs an ordinary intercept -- realtime or turn based, whatever
Settings says -- whose brief carries what the wearer said, so they are not
asked to repeat themselves.

Why a second session rather than the interview session: the interview session
is whatever the conversation mode says it is, and in realtime mode that is a
speech-to-speech model with no separable turn detector. The listener is the
one piece both modes share. Both sessions read the same published microphone
track; the room delivers it once and fans it out locally.

Costs while idle: a Deepgram stream for the length of the mission and one short
Gemini Flash call per finished user turn. No LLM listens between turns.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re

from livekit.agents import Agent, AgentSession, StopResponse, llm

from corvus_conversation import (
    ENDPOINT_MAX_S,
    ENDPOINT_MIN_S,
    PIPELINE_IMPORT_ERROR,
    STT_LANGUAGE,
    STT_MODEL,
    WAKE_PHRASE,
    build_text_model,
    templates,
    vad as load_vad,
)

logger = logging.getLogger("corvus-wake")

# Deepgram nova-3 keyterm prompting: the name is invented, so without a hint
# it comes back as "corpus" or "core vis" more often than not.
WAKE_KEYTERMS = [WAKE_PHRASE, WAKE_PHRASE.split()[-1]]


def parse_verdict(text: str) -> dict:
    """The classifier's JSON, read leniently: the first object in the reply,
    or "not a wake" when there is none."""
    match = re.search(r"\{.*\}", text or "", re.S)
    if not match:
        return {"wake": False, "request": ""}
    try:
        data = json.loads(match.group(0))
    except ValueError:
        return {"wake": False, "request": ""}
    request = data.get("request")
    return {
        "wake": data.get("wake") is True,
        "request": request.strip() if isinstance(request, str) else "",
    }


class GeminiWakeClassifier:
    """One Gemini Flash call per finished turn: was that addressed to Corvus?"""

    def __init__(self, model=None) -> None:
        self.model = model or build_text_model(temperature=0.0)

    async def __call__(self, text: str) -> dict:
        ctx = llm.ChatContext()
        ctx.add_message(
            role="system",
            content=templates.get_template("wake_classify.j2").render(phrase=WAKE_PHRASE),
        )
        ctx.add_message(role="user", content=text)
        parts: list[str] = []
        async with self.model.chat(chat_ctx=ctx) as stream:
            async for chunk in stream:
                delta = getattr(chunk, "delta", None)
                if delta is not None and delta.content:
                    parts.append(delta.content)
        return parse_verdict("".join(parts))


class WakeAgent(Agent):
    """An agent that never answers. The SDK still runs recognition and turn
    detection for it and calls this hook with each finished user turn."""

    def __init__(self, on_turn) -> None:
        super().__init__(instructions="You only listen. You never speak.")
        self._on_turn = on_turn

    async def on_user_turn_completed(self, turn_ctx, new_message) -> None:
        text = (getattr(new_message, "text_content", None) or "").strip()
        if text:
            await self._on_turn(text)
        # Keeps the turn out of the chat context too; nothing accumulates.
        raise StopResponse()


class WakeListener:
    """The mute session and the gate in front of the mission.

    `enabled` is the mission's to set: on while shopping, off during an
    interview so the conversation is not transcribed twice and classified.
    """

    def __init__(
        self,
        room,
        phone: str,
        *,
        classifier,
        vad=None,
        on_wake=None,
        session_cls=AgentSession,
        audio_input=None,
    ) -> None:
        self.room = room
        self.phone = phone
        self.classifier = classifier
        self.preloaded_vad = vad
        self.on_wake = on_wake
        self.session_cls = session_cls
        self.audio_input = audio_input
        self.session = None
        self._enabled = False
        self._classifying = False
        self.turns = 0
        self.wakes = 0

    def make_session(self):
        if PIPELINE_IMPORT_ERROR is not None:
            raise RuntimeError("the wake listener needs the speech plugins (see requirements.txt)") from PIPELINE_IMPORT_ERROR
        from livekit.agents.voice.agent_session import TurnHandlingOptions
        from livekit.agents.voice.turn import EndpointingOptions
        from livekit.plugins import deepgram
        from livekit.plugins.turn_detector.multilingual import MultilingualModel

        return self.session_cls(
            stt=deepgram.STT(model=STT_MODEL, language=STT_LANGUAGE, keyterm=WAKE_KEYTERMS),
            vad=load_vad(self.preloaded_vad),
            user_away_timeout=None,
            turn_handling=TurnHandlingOptions(
                turn_detection=MultilingualModel(),
                preemptive_generation={"enabled": False},
                endpointing=EndpointingOptions(min_delay=ENDPOINT_MIN_S, max_delay=ENDPOINT_MAX_S),
            ),
        )

    async def start(self) -> None:
        from livekit.agents.voice.room_io import RoomOptions

        if self.audio_input is None:
            from corvus_conversation import pipeline_audio_input

            self.audio_input = pipeline_audio_input()
        self.session = self.make_session()
        await self.session.start(
            agent=WakeAgent(self._turn),
            room=self.room,
            room_options=RoomOptions(
                participant_identity=self.phone,
                audio_input=self.audio_input,
                text_input=False,
                video_input=False,
                audio_output=False,
                text_output=False,
                close_on_disconnect=False,
                delete_room_on_close=False,
            ),
        )
        self.session.input.set_audio_enabled(self._enabled)
        logger.info("wake listener started (enabled=%s)", self._enabled)

    @property
    def enabled(self) -> bool:
        return self._enabled

    @enabled.setter
    def enabled(self, value: bool) -> None:
        value = bool(value)
        if value != self._enabled:
            logger.info("wake listening %s", "on" if value else "off")
        self._enabled = value
        if self.session is not None:
            self.session.input.set_audio_enabled(value)

    async def _turn(self, text: str) -> None:
        self.turns += 1
        if not self._enabled or self._classifying:
            return
        self._classifying = True
        try:
            verdict = await asyncio.wait_for(self.classifier(text), 8)
        except Exception:
            logger.exception("wake classification failed")
            return
        finally:
            self._classifying = False
        logger.info("wake turn %r -> %s", text, verdict)
        if not verdict.get("wake"):
            return
        self.wakes += 1
        if self.on_wake is not None and self._enabled:
            await self.on_wake(dict(utterance=text, request=verdict.get("request") or ""))

    async def aclose(self) -> None:
        session, self.session = self.session, None
        self._enabled = False
        if session is not None:
            try:
                await asyncio.wait_for(session.aclose(), 5)
            except Exception:
                logger.exception("wake listener close failed")
