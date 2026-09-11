import asyncio
import unittest
from types import SimpleNamespace

from corvus_conversation import (
    REALTIME,
    TURN_BASED,
    VoiceProfile,
    mode_from_metadata,
    render_topic_prompt,
    topic_from_brief,
)
from corvus_idle import IdleController, turn_at


class ModeTests(unittest.TestCase):
    def test_defaults_to_realtime_and_rejects_unknown(self):
        self.assertEqual(mode_from_metadata({}), REALTIME)
        self.assertEqual(mode_from_metadata({"conversation": "turnBased"}), TURN_BASED)
        with self.assertRaises(ValueError):
            mode_from_metadata({"conversation": "scripted"})


class TopicPromptTests(unittest.TestCase):
    def test_prompt_carries_question_probes_depth_and_tool(self):
        prompt = render_topic_prompt(
            {
                "question": "What made you reach for that one?",
                "probeQuestions": ["Is that the usual one?", "What else did you consider?"],
                "probeDepth": 2,
                "context": "A shopper in a grocery store. Research goal: why this brand.",
            }
        )
        # pulseiq-live-kit's question.j2, verbatim.
        self.assertIn('The initial question to ask is:  "What made you reach for that one?"', prompt)
        self.assertIn("You may ask up to 2 follow-up question(s)", prompt)
        self.assertIn("Is that the usual one?", prompt)
        self.assertIn("What else did you consider?", prompt)
        # Scene and goal are the topic's context; nothing is primed for an intercept.
        self.assertIn("## Additional Context", prompt)
        self.assertNotIn("Topic Playbook", prompt)
        self.assertIn("Research goal: why this brand.", prompt)
        self.assertIn("call `topic_complete`", prompt)
        # Corvus's constraints ride in as the prompt suffix, after the template.
        self.assertLess(prompt.index("## Ending"), prompt.index("Never mention that you are an AI"))
        self.assertNotIn("{{", prompt)

    def test_zero_depth_ends_after_the_initial_answer(self):
        prompt = render_topic_prompt({"question": "Why?", "probeQuestions": [], "probeDepth": 0})
        self.assertIn("There are no follow-on probing questions to ask", prompt)
        self.assertNotIn("Probe Depth", prompt)

    def test_depth_without_prepared_probes_keeps_the_hard_limit(self):
        prompt = render_topic_prompt({"question": "Why?", "probeQuestions": [], "probeDepth": 1})
        self.assertIn("You may ask up to 1 follow-up question(s)", prompt)

    def test_topic_from_old_brief_uses_opening_question(self):
        topic = topic_from_brief({"openingQuestion": "Why that one?", "instructions": "..."})
        self.assertEqual(topic["question"], "Why that one?")
        self.assertEqual(topic["probeDepth"], 2)
        with self.assertRaises(ValueError):
            topic_from_brief({"instructions": "..."})


class FakeSession:
    def __init__(self):
        self.said = []
        self.replies = []

    def say(self, text, **kwargs):
        self.said.append(text)
        return SimpleNamespace(text=text)

    def generate_reply(self, **kwargs):
        self.replies.append(kwargs)
        return SimpleNamespace(kwargs=kwargs)


class FakeAgent:
    def __init__(self):
        self.instructions = None
        self.chat_ctx = SimpleNamespace(items=[SimpleNamespace(id="lk.agent_task.instructions"), SimpleNamespace(id="greeting")])
        self.updated_ctx = None

    async def update_instructions(self, text):
        self.instructions = text

    async def update_chat_ctx(self, ctx):
        self.updated_ctx = ctx


class ProfileTests(unittest.IsolatedAsyncioTestCase):
    async def test_turn_based_installs_topic_clears_context_and_lets_the_model_open(self):
        profile = VoiceProfile(TURN_BASED, lambda: object())
        session, agent = FakeSession(), FakeAgent()
        brief = {
            "openingQuestion": "What made you reach for that one?",
            "instructions": "realtime brief, unused here",
            "topic": {"question": "What made you reach for that one?", "probeQuestions": ["Usual one?"], "probeDepth": 1},
        }
        await profile.begin_interview(session, agent, brief)
        # pulseiq-live-kit's run_initial_flow: prompt, clear, generate_reply().
        self.assertIn("Usual one?", agent.instructions)
        self.assertEqual([i.id for i in agent.updated_ctx.items], ["lk.agent_task.instructions"])
        self.assertEqual(session.replies, [{}])
        self.assertEqual(session.said, [])
        profile.greet(session, "Welcome.")
        self.assertEqual(session.said[-1], "Welcome.")
        self.assertEqual(profile.idle_prompt_seconds, 15)
        self.assertEqual(profile.idle_exit_seconds, 60)

    async def test_turn_based_end_tool_is_topic_complete_and_interrupts_before_ending(self):
        profile = VoiceProfile(TURN_BASED, lambda: object())
        over = asyncio.Event()
        interrupted = []

        class Session:
            async def interrupt(self):
                interrupted.append(True)

        tool = profile.end_tool(over, lambda: Session())
        self.assertEqual(tool.info.name, "topic_complete")
        self.assertEqual(tool.info.description, "Call this when the current topic is complete.")
        # What the Gemini plugin does with the tool before every LLM call. This
        # is where an unresolvable `RunContext` annotation surfaced in the field.
        from livekit.agents import llm
        for t in (tool, VoiceProfile(REALTIME, lambda: object()).end_tool(asyncio.Event(), lambda: None)):
            schema = llm.utils.build_legacy_openai_schema(t, internally_tagged=True)
            self.assertEqual(schema["name"], t.info.name)
        self.assertIsNone(await tool(None))
        await asyncio.wait_for(over.wait(), 1)
        self.assertEqual(interrupted, [True])
        realtime_tool = VoiceProfile(REALTIME, lambda: object()).end_tool(asyncio.Event(), lambda: None)
        self.assertEqual(realtime_tool.info.name, "end_intercept")

    async def test_realtime_hands_the_brief_to_the_model(self):
        profile = VoiceProfile(REALTIME, lambda: object())
        session, agent = FakeSession(), FakeAgent()
        await profile.begin_interview(session, agent, {"openingQuestion": "Why?", "instructions": "BRIEF"})
        self.assertEqual(session.said, [])
        self.assertIn("BRIEF", session.replies[0]["instructions"])
        self.assertIsNone(agent.instructions)
        self.assertIsNone(profile.idle_prompt_seconds)
        self.assertEqual(profile.idle_exit_seconds, 45)
        self.assertIsNone(profile.idle_prompt(session))

    def test_unknown_mode_is_refused(self):
        with self.assertRaises(ValueError):
            VoiceProfile("scripted", lambda: object())


class IdleTests(unittest.IsolatedAsyncioTestCase):
    async def test_prompt_then_exit_on_silence_only_after_agent_spoke(self):
        now = [0.0]
        prompts, exits = [], []

        async def prompt():
            prompts.append(now[0])

        async def exit_():
            exits.append(now[0])

        idle = IdleController(
            None, exit_seconds=45, exit_fn=exit_, prompt_seconds=15, prompt_fn=prompt,
            clock=lambda: now[0],
        )
        # Nothing has been said yet: a long wait is not silence.
        now[0] = 100
        self.assertFalse(await idle.check())
        self.assertEqual(prompts, [])
        idle.set_agent_state("speaking")
        idle.set_agent_state("listening")
        now[0] = 116
        self.assertFalse(await idle.check())
        self.assertEqual(prompts, [116])
        # The wearer answering resets both clocks.
        idle.set_user_state("speaking")
        now[0] = 120
        idle.set_user_state("listening")
        now[0] = 160
        self.assertFalse(await idle.check())
        self.assertEqual(exits, [])
        now[0] = 166
        self.assertTrue(await idle.check())
        self.assertEqual(exits, [166])

    async def test_realtime_has_no_prompt_only_the_exit(self):
        now = [0.0]
        exits = []

        async def exit_():
            exits.append(now[0])

        idle = IdleController(None, exit_seconds=45, exit_fn=exit_, clock=lambda: now[0])
        idle.set_agent_state("speaking")
        idle.set_agent_state("listening")
        now[0] = 44
        self.assertFalse(await idle.check())
        now[0] = 45
        self.assertTrue(await idle.check())
        self.assertEqual(exits, [45])


class TurnTimestampTests(unittest.TestCase):
    def test_prefers_first_audio_frame_and_pulls_user_turns_earlier(self):
        item = SimpleNamespace(created_at=1000.0, metrics={"started_speaking_at": 1001.0})
        self.assertEqual(turn_at(item, "assistant"), 1001.0)
        self.assertEqual(turn_at(item, "user"), 1000.5)
        stale = SimpleNamespace(created_at=1000.0, metrics={"started_speaking_at": 1010.0})
        self.assertEqual(turn_at(stale, "assistant"), 1000.0)
        bare = SimpleNamespace(created_at=1000.0)
        self.assertEqual(turn_at(bare, "user"), 1000.0)


if __name__ == "__main__":
    unittest.main()
