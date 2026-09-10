import unittest
from types import SimpleNamespace
from unittest.mock import patch

from corvus_mission_storage import MissionRecording
from livekit.protocol.egress import EgressStatus


class API:
    def __init__(self, info):
        self.egress = self
        self.result = info

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    async def stop_egress(self, request):
        return self.result

    async def start_room_composite_egress(self, request):
        return self.result


class RecordingTests(unittest.IsolatedAsyncioTestCase):
    async def test_saved_requires_complete_with_file(self):
        none = SimpleNamespace(filename="")
        legacy = SimpleNamespace(filename="recording.mp4")
        for status, files, file, expected in [
            (EgressStatus.EGRESS_COMPLETE, [object()], none, "saved"),
            # What LiveKit actually returns for a one-file room composite:
            # the deprecated single result filled, the list empty.
            (EgressStatus.EGRESS_COMPLETE, [], legacy, "saved"),
            (EgressStatus.EGRESS_FAILED, [], legacy, "failed"),
            (EgressStatus.EGRESS_COMPLETE, [], none, "failed"),
        ]:
            r = MissionRecording("room", "hack/missions/t")
            r.egress_id = "e"

            async def info():
                return SimpleNamespace(status=status, file_results=files, file=file)

            r.info = info
            with patch(
                "corvus_mission_storage.LiveKitAPI",
                lambda: API(
                    SimpleNamespace(status=status, file_results=files, file=file)
                ),
            ):
                await r.stop()
            self.assertEqual(r.status, expected)

    def test_recording_lives_beside_the_manifest(self):
        r = MissionRecording("room", "hack/missions/2026-09-10T05-38-19Z")
        self.assertEqual(
            r.key, "hack/missions/2026-09-10T05-38-19Z/recording.mp4"
        )

    async def test_egress_identity_persisted_before_active_poll(self):
        r = MissionRecording("room", "hack/missions/t")
        observed = []

        async def persist():
            observed.append((r.egress_id, r.status))

        async def info():
            self.assertEqual(observed, [("e", "starting")])
            return SimpleNamespace(
                status=EgressStatus.EGRESS_ACTIVE, started_at=1000000000
            )

        r.on_started = persist
        r.info = info
        creds = {
            "RECORDINGS_S3_BUCKET": "test",
            "AWS_ACCESS_KEY_ID": "test",
            "AWS_SECRET_ACCESS_KEY": "test",
        }
        with (
            patch.dict("os.environ", creds),
            patch(
                "corvus_mission_storage.LiveKitAPI",
                lambda: API(
                    SimpleNamespace(status=EgressStatus.EGRESS_STARTING, egress_id="e")
                ),
            ),
        ):
            await r.start()
        self.assertEqual(r.status, "recording")
        self.assertEqual(r.started_at, 1000)

    async def test_cancelled_manifest_write_finishes_before_terminal_write(self):
        import asyncio
        import threading

        from corvus_mission_storage import MissionStore

        entered = threading.Event()
        release = threading.Event()
        calls = []

        class S3:
            def put_object(self, **kwargs):
                if kwargs["Body"] == b'{"phase": "shopping"}':
                    entered.set()
                    release.wait(2)
                calls.append(kwargs["Body"])

        with (
            patch.dict("os.environ", {"RECORDINGS_S3_BUCKET": "test"}),
            patch("corvus_mission_storage.boto3.client", return_value=S3()),
        ):
            store = MissionStore()
            first = asyncio.create_task(
                store.put("manifest.json", {"phase": "shopping"})
            )
            await asyncio.to_thread(entered.wait, 1)
            first.cancel()
            last = asyncio.create_task(store.put("manifest.json", {"phase": "ended"}))
            for _ in range(5):
                await asyncio.sleep(0)
            self.assertFalse(last.done())
            release.set()
            await asyncio.gather(first, last, return_exceptions=True)
        self.assertEqual(calls[-1], b'{"phase": "ended"}')

