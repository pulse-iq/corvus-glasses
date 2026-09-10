import asyncio
import copy
import unittest
from uuid import uuid4

from corvus_mission import MissionSession, mission_prefix


class Voice:
    def __init__(self):
        self.prepares = 0
        self.calls = []
        self.done = asyncio.Event()
        self.turns = []

    async def prepare(self):
        self.prepares += 1

    async def greet(self, text):
        pass

    async def interview(self, brief, iid):
        self.calls.append(iid)
        self.done.clear()
        await self.done.wait()
        return {"turns": copy.deepcopy(self.turns), "endedBecause": "completed"}

    async def interrupt(self, reason):
        self.done.set()

    async def close(self):
        pass


class Recording:
    def __init__(self):
        self.starts = 0
        self.status = "starting"
        self.key = "video.mp4"
        self.started_at = 1000
        self.egress_id = "egress"

    async def start(self):
        self.starts += 1
        self.status = "recording"

    async def stop(self):
        self.status = "saved"

    async def check(self):
        return self.status


class Store:
    def __init__(self):
        self.values = {}

    async def put(self, key, value):
        self.values[key] = copy.deepcopy(value)


class Room:
    def __init__(self):
        self.deletes = 0

    async def delete(self):
        self.deletes += 1


class MissionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.events = []
        self.voice = Voice()
        self.rec = Recording()
        self.store = Store()
        self.room = Room()
        self.now = 1000
        self.meta = {
            "missionId": str(uuid4()),
            "segmentId": str(uuid4()),
            "version": 1,
            "studyId": "s",
            "sessionId": "log",
        }

        async def send(ev):
            self.events.append(ev)

        self.m = MissionSession(
            self.meta,
            "phone",
            self.voice,
            self.rec,
            self.store,
            self.room,
            send,
            now=lambda: self.now,
        )

    def cmd(self, kind, **payload):
        return dict(
            version=1,
            missionId=self.meta["missionId"],
            segmentId=self.meta["segmentId"],
            operationId=str(uuid4()),
            type=kind,
            payload=payload,
        )

    async def ready(self):
        await self.m.handle(self.cmd("client_ready", cameraReady=True), "phone")
        await self.m.start()

    async def drain(self):
        for _ in range(20):
            await asyncio.sleep(0)

    async def asyncTearDown(self):
        await self.m.end("test_end")

    async def test_three_interviews_share_recording_and_prepared_voice(self):
        await self.ready()
        for n in range(3):
            c = self.cmd(
                "begin_intercept",
                studyId="s",
                itemId=str(n),
                itemName="Milk",
                instructions="Ask",
                openingQuestion="Why?",
                triggeredAtMs=self.now,
            )
            c["interceptId"] = str(uuid4())
            await self.m.handle(c, "phone")
            await self.drain()
            self.voice.done.set()
            await self.drain()
            self.assertEqual(self.m.phase, "shopping")
        self.assertEqual(self.rec.starts, 1)
        self.assertEqual(self.room.deletes, 0)
        self.assertEqual(len(self.voice.calls), 3)
        self.assertEqual(self.voice.prepares, 5)

    async def test_duplicate_and_unauthorized_begin(self):
        await self.ready()
        c = self.cmd(
            "begin_intercept",
            studyId="s",
            itemId="i",
            itemName="Milk",
            instructions="Ask",
            openingQuestion="Why?",
            triggeredAtMs=self.now,
        )
        c["interceptId"] = str(uuid4())
        self.assertEqual((await self.m.handle(c, "other"))["type"], "rejected")
        a = await self.m.handle(c, "phone")
        b = await self.m.handle(c, "phone")
        await self.drain()
        self.assertEqual(a, b)
        self.assertEqual(len(self.voice.calls), 1)

    async def test_heartbeat_loss_gates_new_interviews(self):
        await self.ready()
        self.now += 7000
        await self.m.tick()
        self.assertEqual(self.m.phase, "reconnecting")

    async def test_end_during_setup_never_welcomes(self):
        await self.m.end("user_ended")
        await self.m.start()
        self.assertEqual(self.m.phase, "ended")
        self.assertEqual(self.rec.starts, 0)

    async def test_end_cancels_suspended_setup(self):
        entered = asyncio.Event()

        async def blocked():
            entered.set()
            await asyncio.Event().wait()

        self.voice.prepare = blocked
        task = asyncio.create_task(self.m.start())
        await entered.wait()
        await self.m.end("user_ended")
        self.assertTrue(task.cancelled())
        self.assertEqual(self.room.deletes, 1)
        self.assertEqual(self.m.phase, "ended")

    async def test_storage_failure_still_closes_voice_and_room(self):
        closed = []

        async def close():
            closed.append(True)

        async def fail(*args):
            raise RuntimeError("disk failure")

        self.voice.close = close
        self.store.put = fail
        await self.m.end("user_ended")
        self.assertEqual(closed, [True])
        self.assertEqual(self.room.deletes, 1)

    async def test_rejects_duplicate_intercept_id_under_new_operation(self):
        await self.ready()
        c = self.cmd(
            "begin_intercept",
            studyId="s",
            itemId="i",
            itemName="Milk",
            instructions="Ask",
            openingQuestion="Why?",
            triggeredAtMs=self.now,
        )
        c["interceptId"] = str(uuid4())
        await self.m.handle(c, "phone")
        await self.drain()
        self.voice.done.set()
        await self.drain()
        c["operationId"] = str(uuid4())
        self.assertEqual((await self.m.handle(c, "phone"))["type"], "rejected")

    async def test_finalization_timeout_retains_room_and_pending_status(self):
        await self.ready()

        async def pending():
            raise asyncio.TimeoutError()

        self.rec.stop = pending
        await self.m.end("user_ended")
        self.assertEqual(self.rec.status, "finalizing")
        self.assertEqual(self.room.deletes, 0)

    async def test_operation_payload_conflict_rejected(self):
        await self.ready()
        c = self.cmd("sync")
        await self.m.handle(c, "phone")
        c["type"] = "end_mission"
        self.assertEqual(
            (await self.m.handle(c, "phone"))["payload"]["reason"], "operation_conflict"
        )
        self.assertEqual(self.m.phase, "shopping")

    async def test_end_while_accept_send_suspended_does_not_start_interview(self):
        await self.ready()
        entered = asyncio.Event()
        release = asyncio.Event()

        async def send(event):
            if event["type"] == "accepted" and event.get("interceptId"):
                entered.set()
                await release.wait()
            self.events.append(event)

        self.m.send = send
        c = self.cmd(
            "begin_intercept",
            studyId="s",
            itemId="i",
            itemName="Milk",
            instructions="Ask",
            openingQuestion="Why?",
            triggeredAtMs=self.now,
        )
        c["interceptId"] = str(uuid4())
        task = asyncio.create_task(self.m.handle(c, "phone"))
        await entered.wait()
        await self.m.end("user_ended")
        release.set()
        await task
        await self.drain()
        self.assertEqual(self.voice.calls, [])
        self.assertEqual(self.m.phase, "ended")

    async def test_no_time_limit_on_a_long_quiet_mission(self):
        await self.ready()
        self.now += 3 * 60 * 60_000
        self.m.heartbeat = self.now
        await self.m.tick()
        self.assertEqual(self.m.phase, "shopping")
        self.assertNotIn("deadlineMs", self.m.snapshot())

    async def test_end_reason_preserved(self):
        await self.ready()
        await self.m.handle(
            self.cmd("end_mission", reason="setup_failed"), "phone"
        )
        self.assertEqual(
            self.events[-1]["payload"]["endedBecause"], "setup_failed"
        )

    async def test_end_cancels_post_interview_preparation(self):
        await self.ready()
        entered = asyncio.Event()

        async def blocked():
            entered.set()
            await asyncio.Event().wait()

        self.voice.prepare = blocked
        c = self.cmd(
            "begin_intercept",
            studyId="s",
            itemId="i",
            itemName="Milk",
            instructions="Ask",
            openingQuestion="Why?",
            triggeredAtMs=self.now,
        )
        c["interceptId"] = str(uuid4())
        await self.m.handle(c, "phone")
        await self.drain()
        self.voice.done.set()
        await entered.wait()
        await self.m.end("user_ended")
        self.assertTrue(self.m.interview_task.cancelled())
        self.assertEqual(self.m.phase, "ended")

    async def test_heartbeat_repeats_shopping_state(self):
        await self.ready()
        self.events.clear()
        await self.m.handle(self.cmd("client_ready", cameraReady=True), "phone")
        self.assertTrue(
            any(
                e["type"] == "state" and e["payload"]["phase"] == "shopping"
                for e in self.events
            )
        )

    async def test_interrupt_failure_preserves_partial_transcript(self):
        await self.ready()
        self.voice.turns = [{"role": "user", "text": "Milk", "atMs": 1000}]
        c = self.cmd(
            "begin_intercept",
            studyId="s",
            itemId="i",
            itemName="Milk",
            instructions="Ask",
            openingQuestion="Why?",
            triggeredAtMs=self.now,
        )
        c["interceptId"] = str(uuid4())
        await self.m.handle(c, "phone")
        await self.drain()

        async def fail(reason):
            raise RuntimeError("voice transport already closed")

        self.voice.interrupt = fail
        await self.m.end("user_ended")
        manifest = self.store.values[self.m.prefix + "/manifest.json"]
        interview = next(
            i for i in manifest["interviews"] if i["interceptId"] == c["interceptId"]
        )
        self.assertEqual(interview["turns"], self.voice.turns)
        self.assertEqual(
            [k for k in self.store.values if "/interviews/" in k], []
        )

    async def test_recording_finalization_does_not_change_mission_end_time(self):
        await self.ready()
        ended = self.now

        async def stop():
            self.now += 20000
            self.rec.status = "saved"

        self.rec.stop = stop
        await self.m.end("user_ended")
        self.assertEqual(
            self.store.values[self.m.prefix + "/manifest.json"]["endedAtMs"], ended
        )
        terminal = next(e for e in self.events if e["type"] == "mission_ended")
        self.assertEqual(terminal["payload"]["endedAtMs"], ended)


class PrefixTests(unittest.TestCase):
    def test_prefix_is_the_mission_start_time(self):
        # 2026-09-10 05:38:19 UTC
        self.assertEqual(
            mission_prefix(1789018699128), "hack/missions/2026-09-10T05-38-19Z"
        )

    def test_session_defaults_prefix_from_its_clock(self):
        m = MissionSession(
            {"missionId": str(uuid4()), "segmentId": str(uuid4())},
            "phone",
            None,
            type("R", (), {"key": "", "status": "", "egress_id": None, "started_at": None})(),
            None,
            None,
            None,
            now=lambda: 1789018699128,
        )
        self.assertEqual(m.prefix, "hack/missions/2026-09-10T05-38-19Z")
