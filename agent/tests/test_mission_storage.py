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
        for status, files, expected in [
            (EgressStatus.EGRESS_COMPLETE, [object()], "saved"),
            (EgressStatus.EGRESS_FAILED, [], "failed"),
            (EgressStatus.EGRESS_COMPLETE, [], "failed"),
        ]:
            r = MissionRecording("room", "mission", "segment")
            r.egress_id = "e"

            async def info():
                return SimpleNamespace(status=status, file_results=files)

            r.info = info
            with patch(
                "corvus_mission_storage.LiveKitAPI",
                lambda: API(SimpleNamespace(status=status, file_results=files)),
            ):
                await r.stop()
            self.assertEqual(r.status, expected)

    async def test_egress_identity_persisted_before_active_poll(self):
        r = MissionRecording("room", "mission", "segment")
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

    async def test_interview_write_is_immutable(self):
        from corvus_mission_storage import MissionStore

        calls = []

        class S3:
            def put_object(self, **kwargs):
                calls.append(kwargs)

        with (
            patch.dict("os.environ", {"RECORDINGS_S3_BUCKET": "test"}),
            patch("corvus_mission_storage.boto3.client", return_value=S3()),
        ):
            store = MissionStore()
            await store.put("root/interviews/id.json", {"turns": []})
        self.assertEqual(calls[0].get("IfNoneMatch"), "*")

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

    async def test_conflicting_immutable_result_is_rejected(self):
        import io

        from botocore.exceptions import ClientError
        from corvus_mission_storage import MissionStore

        class S3:
            def put_object(self, **kwargs):
                raise ClientError(
                    {"ResponseMetadata": {"HTTPStatusCode": 412}}, "PutObject"
                )

            def get_object(self, **kwargs):
                return {"Body": io.BytesIO(b'{"turns":["original"]}')}

        with (
            patch.dict("os.environ", {"RECORDINGS_S3_BUCKET": "test"}),
            patch("corvus_mission_storage.boto3.client", return_value=S3()),
        ):
            store = MissionStore()
            with self.assertRaisesRegex(
                RuntimeError, "Immutable interview result conflict"
            ):
                await store.put("root/interviews/id.json", {"turns": ["replacement"]})
