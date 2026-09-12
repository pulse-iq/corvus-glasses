import asyncio
import unittest
from types import SimpleNamespace

from corvus_conversation import REALTIME, TURN_BASED, WAKE_KIND, VoiceProfile, render_wake_prompt
from corvus_wake import WakeAgent, WakeListener, parse_verdict
from livekit.agents import StopResponse


class VerdictTests(unittest.TestCase):
    def test_reads_the_first_json_object_and_defaults_to_no_wake(self):
        self.assertEqual(
            parse_verdict('Sure.\n{"wake": true, "request": " what is this "}'),
            {"wake": True, "request": "what is this"},
        )
        self.assertEqual(parse_verdict('{"wake": false}'), {"wake": False, "request": ""})
        self.assertEqual(parse_verdict("not json"), {"wake": False, "request": ""})
        self.assertEqual(parse_verdict('{"wake": "yes"}')["wake"], False)


class WakePromptTests(unittest.TestCase):
    def test_each_mode_gets_its_own_template_with_the_utterance(self):
        brief = {"kind": WAKE_KIND, "wakeUtterance": "hey corvus is this gluten free", "wakeRequest": "is this gluten free"}
        realtime = render_wake_prompt(REALTIME, brief)
        pipeline = render_wake_prompt(TURN_BASED, brief)
        for prompt in (realtime, pipeline):
            self.assertIn("hey corvus is this gluten free", prompt)
            self.assertIn("is this gluten free", prompt)
            self.assertNotIn("{{", prompt)
        self.assertIn("end_intercept", realtime)
        self.assertIn("topic_complete", pipeline)
        # No request line when the classifier gave none.
        bare = render_wake_prompt(REALTIME, {"wakeUtterance": "hey corvus"})
        self.assertNotIn("What they want", bare)


class Session:
    def __init__(self):
        self.said, self.replies = [], []

    def say(self, text, **kwargs):
        self.said.append(text)

    def generate_reply(self, **kwargs):
        self.replies.append(kwargs)


class Agent_:
    def __init__(self):
        self.instructions = None
        self.chat_ctx = SimpleNamespace(items=[])

    async def update_instructions(self, text):
        self.instructions = text

    async def update_chat_ctx(self, ctx):
        pass


class ProfileWakeTests(unittest.IsolatedAsyncioTestCase):
    async def test_wake_brief_bypasses_the_study_prompts_in_both_modes(self):
        brief = {"kind": WAKE_KIND, "openingQuestion": "what is this", "wakeUtterance": "hey corvus what is this", "wakeRequest": "what is this"}
        session, agent = Session(), Agent_()
        await VoiceProfile(REALTIME, lambda: object()).begin_interview(session, agent, brief)
        self.assertIn("hey corvus what is this", session.replies[0]["instructions"])
        self.assertNotIn("study brief", session.replies[0]["instructions"])
        session, agent = Session(), Agent_()
        await VoiceProfile(TURN_BASED, lambda: object()).begin_interview(session, agent, brief)
        self.assertIn("topic_complete", agent.instructions)
        self.assertNotIn("initial question to ask", agent.instructions)
        self.assertEqual(session.replies, [{}])


class Gate:
    def __init__(self):
        self.enabled = None

    def set_audio_enabled(self, value):
        self.enabled = value


class FakeSession:
    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.input = Gate()
        self.started = None
        self.closed = False

    async def start(self, **kwargs):
        self.started = kwargs

    async def aclose(self):
        self.closed = True


class ListenerTests(unittest.IsolatedAsyncioTestCase):
    def listener(self, verdicts):
        wakes = []

        async def classify(text):
            return verdicts[text]

        async def on_wake(hit):
            wakes.append(hit)

        listener = WakeListener(object(), "phone", classifier=classify, on_wake=on_wake, session_cls=FakeSession, audio_input=True)
        listener.make_session = lambda: FakeSession()
        return listener, wakes

    async def test_agent_hook_reports_the_turn_and_stops_any_response(self):
        seen = []

        async def on_turn(text):
            seen.append(text)

        agent = WakeAgent(on_turn)
        with self.assertRaises(StopResponse):
            await agent.on_user_turn_completed(None, SimpleNamespace(text_content="  hey corvus  "))
        self.assertEqual(seen, ["hey corvus"])

    async def test_only_enabled_turns_are_classified_and_only_wakes_reach_the_mission(self):
        listener, wakes = self.listener({
            "hey corvus what is this": {"wake": True, "request": "what is this"},
            "I think we need milk": {"wake": False, "request": ""},
        })
        await listener.start()
        self.assertIs(listener.session.input.enabled, False)
        self.assertEqual(listener.session.started["room_options"].audio_output, False)
        await listener._turn("hey corvus what is this")
        self.assertEqual(wakes, [])  # gate closed: not even classified
        listener.enabled = True
        self.assertIs(listener.session.input.enabled, True)
        await listener._turn("I think we need milk")
        self.assertEqual(wakes, [])
        await listener._turn("hey corvus what is this")
        self.assertEqual(wakes, [{"utterance": "hey corvus what is this", "request": "what is this"}])
        await listener.aclose()
        self.assertIsNone(listener.session)

    async def test_classifier_failure_is_swallowed(self):
        async def broken(text):
            raise RuntimeError("quota")

        listener = WakeListener(object(), "phone", classifier=broken, on_wake=None, session_cls=FakeSession, audio_input=True)
        listener.enabled = True
        await listener._turn("hey corvus")
        self.assertEqual(listener.wakes, 0)


if __name__ == "__main__":
    unittest.main()
