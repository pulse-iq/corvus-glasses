"""How a mission talks to the wearer.

Two modes share one mission, one room, one recording and one transcript path:

- ``realtime``: a single speech-to-speech model (Gemini Live or OpenAI realtime,
  chosen by the phone's ``engine`` field). Sub-second, interruptible, and it
  holds the floor for the whole conversation.
- ``turnBased``: pulseiq-live-kit's pipeline, ported as faithfully as the
  mission allows. Deepgram recognition, Gemini Flash as the text model,
  ElevenLabs voice, Silero, the multilingual turn detector, its endpointing and
  interruption settings, its ``question.j2`` prompt verbatim, its
  ``topic_complete`` tool, its interrupt-then-advance ending, and its idle
  clocks. Where pulseiq-live-kit has a rule, that rule is used; nothing about
  how the conversation is conducted is invented here.

Each intercept runs one topic in pulseiq-live-kit's sense: an opening question,
optional probe questions, a probe depth, and context. The topic arrives
in the intercept brief from the phone. Realtime keeps the phone-composed
instructions it always had.

Deliberate departures from pulseiq-live-kit, all mechanics rather than
conversation rules: the mission greeting is literal speech (``session.say``)
because it is not a topic; the study's scene and research goal are the topic's
``context``, and the template's primed-context playbook (their reasoning pass
over earlier conversations, which an intercept never has) is removed from our
copy, with the context block rendered on its own as their voice templates do;
and the intercept-specific constraints a shopper needs (never answer product
questions, never say what you are) go in through the same per-interview
prompt-suffix mechanism pulseiq-live-kit uses, from ``prompts/corvus_suffix.j2``.

`main.py` imports this module at startup so the speech plugins register before
the worker forks its inference process (the turn detector runs there), and
installs :func:`prewarm` so Silero loads once per job process.
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from jinja2 import Environment, FileSystemLoader
# Module level on purpose: with postponed annotations the SDK resolves a tool's
# `ctx: RunContext` hint against this module's globals when it builds the
# function schema, and a name imported inside a method is not there.
from livekit.agents import RunContext, function_tool

logger = logging.getLogger("corvus-conversation")

REALTIME = "realtime"
TURN_BASED = "turnBased"
MODES = (REALTIME, TURN_BASED)

# Providers and settings match pulseiq-live-kit (src/agent.py::_create_session,
# session/speech/{stt,tts}.py). Keys: DEEPGRAM_API_KEY (read by the plugin),
# ELEVENLABS_API_KEY (pulseiq's name; the plugin's own ELEVEN_API_KEY also
# works), GOOGLE_API_KEY or GEMINI_API_KEY.
STT_MODEL = "nova-3"
STT_LANGUAGE = "en-US"
TTS_MODEL = "eleven_turbo_v2_5"
TTS_VOICE = os.environ.get("ELEVENLABS_VOICE_ID", "UgBBYS2sOqTuMpoF3BR0")
LLM_MODEL = os.environ.get("CORVUS_TURN_MODEL", "gemini-2.5-flash")
ENDPOINT_MIN_S = 0.6
ENDPOINT_MAX_S = 4.0

# pulseiq-live-kit's idle clocks (idle.py): a spoken nudge, then an exit.
TURN_BASED_IDLE_PROMPT_SECONDS = 15
TURN_BASED_IDLE_EXIT_SECONDS = 60
IDLE_PROMPT_TEXT = "Are you still there?"
# Corvus's own exit for the realtime model, which is told to handle silence
# itself; unchanged from before the turn-based mode existed.
REALTIME_IDLE_EXIT_SECONDS = float(os.environ.get("CORVUS_IDLE_EXIT_SECONDS", "45"))

# The chat item that survives a context clear, as in pulseiq-live-kit's
# messages.py.
INSTRUCTIONS_ID = "lk.agent_task.instructions"

try:
    from livekit.agents.voice.agent_session import TurnHandlingOptions
    from livekit.agents.voice.room_io import AudioInputOptions
    from livekit.agents.voice.turn import EndpointingOptions
    from livekit.plugins import deepgram, elevenlabs, google, noise_cancellation, silero
    from livekit.plugins.turn_detector.multilingual import MultilingualModel

    PIPELINE_IMPORT_ERROR: Exception | None = None
except ImportError as error:  # tests without the speech plugins installed
    PIPELINE_IMPORT_ERROR = error


def mode_from_metadata(meta: dict) -> str:
    """The conversation mode the phone asked for; realtime when it said nothing."""
    value = meta.get("conversation") or REALTIME
    if value not in MODES:
        raise ValueError(f"unsupported conversation mode: {value!r}")
    return value


# ---------------------------------------------------------------- the topic prompt

_templates = Environment(loader=FileSystemLoader(Path(__file__).parent / "prompts"))


def topic_from_brief(brief: dict) -> dict:
    """The topic in an intercept brief, or one made from the opening question
    alone for a phone that predates topics."""
    topic = dict(brief.get("topic") or {})
    topic.setdefault("question", brief.get("openingQuestion") or "")
    topic.setdefault("probeQuestions", [])
    topic.setdefault("probeDepth", 2)
    topic.setdefault("context", None)
    if not topic["question"]:
        raise ValueError("intercept brief carries no opening question")
    return topic


def render_topic_prompt(topic: dict) -> str:
    """pulseiq-live-kit's ``system_prompt`` for a QUESTION topic.

    Same template, same variables (prompts/__init__.py::get_question_prompt)
    minus the primed playbook, which this project does not have: no prior
    transcript and no respondent background, because an intercept is one topic;
    the study's scene and goal as ``context``, where an interview's own context
    goes. Then the prompt suffix, appended the way ``build_system_prompt``
    appends an interview's own.
    """
    probes = [p.strip() for p in (topic.get("probeQuestions") or []) if p and p.strip()]
    depth = topic.get("probeDepth")
    depth = len(probes) if depth is None else max(0, int(depth))
    prompt = _templates.get_template("question.j2").render(
        question=topic["question"].strip(),
        probe_questions=probes,
        probe_depth=depth,
        transcript_context=None,
        context=(topic.get("context") or "").strip() or None,
        respondent_context=None,
    )
    suffix = _templates.get_template("corvus_suffix.j2").render().strip()
    if suffix:
        prompt += f"\n\n{suffix}"
    return prompt


# ---------------------------------------------------------------- the sessions

_vad = None


def prewarm(proc) -> None:
    """pulseiq-live-kit's ``prewarm``: Silero loads once per job process."""
    proc.userdata["vad"] = silero.VAD.load()


def vad(preloaded=None):
    global _vad
    if preloaded is not None:
        return preloaded
    if _vad is None:
        _vad = silero.VAD.load()
    return _vad


def build_pipeline_session(session_cls, preloaded_vad=None):
    """pulseiq-live-kit's session, provider for provider and setting for setting."""
    if PIPELINE_IMPORT_ERROR is not None:
        raise RuntimeError(
            "turn-based conversation needs the silero, turn-detector, deepgram, "
            "elevenlabs and noise-cancellation plugins (see requirements.txt)"
        ) from PIPELINE_IMPORT_ERROR
    return session_cls(
        stt=deepgram.STT(model=STT_MODEL, language=STT_LANGUAGE),
        llm=google.LLM(
            model=LLM_MODEL,
            api_key=os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_API_KEY") or None,
            temperature=0.2,
            thinking_config={"thinking_budget": 0},
        ),
        tts=elevenlabs.TTS(
            model=TTS_MODEL,
            voice_id=TTS_VOICE,
            api_key=os.environ.get("ELEVENLABS_API_KEY") or None,
        ),
        vad=vad(preloaded_vad),
        # Idleness belongs to IdleController; the SDK's own away detection stays off.
        user_away_timeout=None,
        turn_handling=TurnHandlingOptions(
            turn_detection=MultilingualModel(),
            # A dict, not False: the SDK rejects a bare boolean here.
            preemptive_generation={"enabled": False},
            endpointing=EndpointingOptions(min_delay=ENDPOINT_MIN_S, max_delay=ENDPOINT_MAX_S),
        ),
        # ElevenLabs returns word timings, which is what makes the transcript
        # trustworthy about how much of a line was actually heard.
        use_tts_aligned_transcript=True,
    )


async def clear_chat_context(agent) -> None:
    """pulseiq-live-kit's ``_clear_chat_context``: keep only the instructions."""
    try:
        from livekit.agents import llm

        kept = [i for i in agent.chat_ctx.items if getattr(i, "id", None) == INSTRUCTIONS_ID]
        await agent.update_chat_ctx(llm.ChatContext(items=kept))
    except Exception:
        logger.exception("could not clear the chat context")


class VoiceProfile:
    """Everything about a mission's voice session that differs by mode.

    `MissionVoice` owns the lifecycle -- prepare, greet, interview, close --
    and asks this for the parts that depend on what is behind the session.
    """

    def __init__(self, mode: str, realtime_model_factory, vad=None) -> None:
        if mode not in MODES:
            raise ValueError(f"unsupported conversation mode: {mode!r}")
        self.mode = mode
        self.realtime_model_factory = realtime_model_factory
        self.preloaded_vad = vad

    @property
    def realtime(self) -> bool:
        return self.mode == REALTIME

    @property
    def idle_prompt_seconds(self) -> float | None:
        return None if self.realtime else TURN_BASED_IDLE_PROMPT_SECONDS

    @property
    def idle_exit_seconds(self) -> float:
        return REALTIME_IDLE_EXIT_SECONDS if self.realtime else TURN_BASED_IDLE_EXIT_SECONDS

    def make_session(self, session_cls):
        if self.realtime:
            return session_cls(llm=self.realtime_model_factory())
        return build_pipeline_session(session_cls, self.preloaded_vad)

    def room_audio_input(self):
        """pulseiq-live-kit runs Background Voice Cancellation on the room's
        audio input (a LiveKit Cloud feature); a shop floor wants it at least
        as much as an interview room does."""
        if self.realtime or PIPELINE_IMPORT_ERROR is not None:
            return True
        return AudioInputOptions(noise_cancellation=noise_cancellation.BVC())

    def end_tool(self, over: asyncio.Event, session_getter):
        """The one tool the model has.

        Realtime keeps Corvus's ``end_intercept``. The pipeline gets
        pulseiq-live-kit's ``topic_complete``, name and docstring included, and
        its behaviour: return nothing, then interrupt the session from a task
        scheduled after the tool call, which cancels the SDK's post-tool
        continuation so the model never speaks past the end.
        """
        if self.realtime:

            @function_tool
            async def end_intercept(ctx: RunContext):
                """Call after your closing line. End only this product interview. Say nothing afterward."""
                over.set()

            return end_intercept

        async def finish():
            session = session_getter()
            if session is not None:
                try:
                    await session.interrupt()
                except Exception:
                    logger.exception("interrupt after topic_complete failed")
            over.set()

        @function_tool(name="topic_complete", description="Call this when the current topic is complete.")
        async def topic_complete(ctx: RunContext):
            logger.info("topic_complete called")
            asyncio.create_task(finish())
            return None

        return topic_complete

    def greet(self, session, text: str):
        """Say the welcome. Literal speech on the pipeline; a realtime model has
        no separate voice, so it is asked to repeat the line."""
        if self.realtime:
            return session.generate_reply(
                user_input="Please greet the shopper now. Say exactly: " + text
            )
        return session.say(text)

    async def begin_interview(self, session, agent, brief: dict):
        """Open the intercept.

        Realtime hands the model the phone-composed brief and lets it speak.
        The pipeline does what pulseiq-live-kit's ``run_initial_flow`` does for
        a topic: install the rendered prompt, clear the chat context, and
        ``generate_reply()`` so the model asks the initial question -- which the
        template requires verbatim.
        """
        if self.realtime:
            session.generate_reply(
                instructions="Conduct this interview following the complete study brief:\n"
                + brief["instructions"]
                + "\nBegin now. Say this opening question exactly: "
                + brief["openingQuestion"]
            )
            return
        topic = topic_from_brief(brief)
        await agent.update_instructions(render_topic_prompt(topic))
        await clear_chat_context(agent)
        session.generate_reply()

    def idle_prompt(self, session):
        """The spoken nudge. Pipeline only; realtime is told to handle silence."""
        if self.realtime:
            return None
        return session.say(IDLE_PROMPT_TEXT, allow_interruptions=True)
