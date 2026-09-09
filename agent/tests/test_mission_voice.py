import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from corvus_mission_voice import MissionVoice
from livekit.agents import AgentSession
from livekit.agents.voice.room_io import RoomOptions


class Gate:
    def __init__(self):
        self.enabled = True

    def set_audio_enabled(self, value):
        self.enabled = value


class Session:
    def __init__(self, **kwargs):
        self.input = Gate()
        self.output = Gate()
        self.handlers = {}
        self.closed = False
        self.current_speech = None

        async def room_ready():
            pass

        self.room_io = SimpleNamespace(wait_for_ready=room_ready)

    def on(self, event):
        def register(fn):
            self.handlers[event] = fn
            return fn

        return register

    async def start(self, **kwargs):
        self.options = kwargs["room_options"]
        assert not self.input.enabled
        assert not self.output.enabled
        self.handlers["metrics_collected"](
            SimpleNamespace(metrics=SimpleNamespace(request_id="", acquire_time=0.1))
        )

    async def aclose(self):
        self.closed = True

    def interrupt(self, **kwargs):
        async def done():
            pass

        return asyncio.create_task(done())

    def generate_reply(self, **kwargs):
        async def done():
            pass

        return SimpleNamespace(
            wait_for_playout=done,
            exception=lambda: None,
            chat_items=[SimpleNamespace(role="assistant", text_content="Hello")],
        )


class VoiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_prepare_gates_ambient_and_replaces_session_without_room_deletion(
        self,
    ):
        with patch("corvus_mission_voice.AgentSession", Session):
            v = MissionVoice(object(), "phone", lambda: object())
            await v.prepare()
            first = v.session
            self.assertFalse(first.input.enabled)
            self.assertFalse(first.output.enabled)
            self.assertFalse(first.options.close_on_disconnect)
            self.assertFalse(first.options.delete_room_on_close)
            await v.greet("Hello")
            self.assertFalse(first.output.enabled)
            await v.prepare()
            self.assertTrue(first.closed)
            self.assertIsNot(first, v.session)
            await v.close()

    async def test_real_sdk_supports_quiet_controls_and_room_ownership_options(self):
        session = AgentSession()
        session.input.set_audio_enabled(False)
        session.output.set_audio_enabled(False)
        options = RoomOptions(
            text_input=False,
            video_input=False,
            close_on_disconnect=False,
            delete_room_on_close=False,
            participant_identity="phone",
        )
        self.assertFalse(options.close_on_disconnect)
        self.assertFalse(session.input.audio_enabled)

    async def test_prepare_waits_for_provider_connection_and_close_wakes_it(self):
        class Deferred(Session):
            async def start(self, **kwargs):
                self.options = kwargs["room_options"]

        with patch("corvus_mission_voice.AgentSession", Deferred):
            v = MissionVoice(object(), "phone", lambda: object())
            task = asyncio.create_task(v.prepare())
            for _ in range(4):
                await asyncio.sleep(0)
            self.assertFalse(task.done())
            await v.close()
            await asyncio.gather(task, return_exceptions=True)
            self.assertTrue(v.session.closed)

    async def test_close_during_old_session_close_does_not_allocate_replacement(self):
        with patch("corvus_mission_voice.AgentSession", Session):
            v = MissionVoice(object(), "phone", lambda: object())
            await v.prepare()
            first = v.session
            entered = asyncio.Event()
            release = asyncio.Event()

            async def close_old():
                entered.set()
                await release.wait()
                first.closed = True

            first.aclose = close_old
            task = asyncio.create_task(v.prepare())
            await entered.wait()
            close = asyncio.create_task(v.close())
            await asyncio.sleep(0)
            release.set()
            await asyncio.gather(task, close, return_exceptions=True)
            self.assertIs(v.session, first)

    async def test_turn_timestamp_uses_source_chat_message_created_at(self):
        with patch("corvus_mission_voice.AgentSession", Session):
            v = MissionVoice(object(), "phone", lambda: object())
            await v.prepare()
            v.active = True
            v.session.handlers["conversation_item_added"](
                SimpleNamespace(
                    item=SimpleNamespace(
                        role="user", text_content="Hello", created_at=1234.5
                    )
                )
            )
            self.assertEqual(v.turns[0]["atMs"], 1234500)
            await v.close()

    async def test_close_during_new_session_start_closes_late_session(self):
        entered = asyncio.Event()
        release = asyncio.Event()

        class Deferred(Session):
            async def start(self, **kwargs):
                entered.set()
                await release.wait()

        with patch("corvus_mission_voice.AgentSession", Deferred):
            v = MissionVoice(object(), "phone", lambda: object())
            task = asyncio.create_task(v.prepare())
            await entered.wait()
            await v.close()
            release.set()
            await task
            self.assertTrue(v.session.closed)
            self.assertFalse(v.session.input.enabled)
            self.assertFalse(v.session.output.enabled)

    async def test_replacing_voice_unpublishes_only_its_output_track(self):
        publications = {"existing": SimpleNamespace(name="other-audio")}
        removed = []

        class Participant:
            track_publications = publications

            async def unpublish_track(self, sid):
                removed.append(sid)
                publications.pop(sid)

        room = SimpleNamespace(local_participant=Participant())

        class Publishing(Session):
            async def start(self, **kwargs):
                await super().start(**kwargs)
                publications["voice-" + str(id(self))] = SimpleNamespace(
                    name="roomio_audio"
                )

        with patch("corvus_mission_voice.AgentSession", Publishing):
            v = MissionVoice(room, "phone", lambda: object())
            await v.prepare()
            first_sid = "voice-" + str(id(v.session))
            await v.prepare()
            self.assertEqual(removed, [first_sid])
            self.assertIn("existing", publications)
            await v.close()
            self.assertEqual(list(publications), ["existing"])

    async def test_prepare_waits_for_room_audio_subscription(self):
        entered = asyncio.Event()
        release = asyncio.Event()

        class Unsubscribed(Session):
            def __init__(self, **kwargs):
                super().__init__(**kwargs)

                async def room_ready():
                    entered.set()
                    await release.wait()

                self.room_io = SimpleNamespace(wait_for_ready=room_ready)

        with patch("corvus_mission_voice.AgentSession", Unsubscribed):
            v = MissionVoice(object(), "phone", lambda: object())
            task = asyncio.create_task(v.prepare())
            for _ in range(5):
                await asyncio.sleep(0)
            self.assertFalse(task.done())
            release.set()
            await task
            await v.close()

    async def test_greeting_uses_explicit_user_command_and_requires_output(self):
        with patch("corvus_mission_voice.AgentSession", Session):
            v = MissionVoice(object(), "phone", lambda: object())
            await v.prepare()
            calls = []

            def reply(**kwargs):
                calls.append(kwargs)

                async def done():
                    pass

                return SimpleNamespace(
                    wait_for_playout=done, exception=lambda: None, chat_items=[]
                )

            v.session.generate_reply = reply
            with self.assertRaisesRegex(
                RuntimeError, "Welcome produced no assistant speech"
            ):
                await v.greet("Hello")
            self.assertEqual(
                calls[0].get("user_input"),
                "Please greet the shopper now. Say exactly: Hello",
            )
            self.assertEqual(v.turns, [])
            await v.close()

    async def test_close_disposes_session_after_interrupt_error(self):
        with patch("corvus_mission_voice.AgentSession", Session):
            v = MissionVoice(object(), "phone", lambda: object())
            await v.prepare()

            async def fail(reason):
                raise RuntimeError("transport closed")

            v.interrupt = fail
            with self.assertRaisesRegex(RuntimeError, "transport closed"):
                await v.close()
            self.assertTrue(v.session.closed)

    async def test_close_is_idempotent_for_concurrent_and_repeated_calls(self):
        with patch("corvus_mission_voice.AgentSession", Session):
            v = MissionVoice(object(), "phone", lambda: object())
            await v.prepare()
            calls = []
            original = v.interrupt

            async def once(reason):
                if v.session.closed:
                    raise RuntimeError("AgentSession isn't running")
                calls.append(reason)
                await original(reason)

            v.interrupt = once
            await asyncio.gather(v.close(), v.close())
            await v.close()
            self.assertEqual(calls, ["mission_ended"])
            self.assertTrue(v.session.closed)
