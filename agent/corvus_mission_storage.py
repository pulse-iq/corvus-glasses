"""Durable S3 manifests and verified LiveKit egress finalization."""

import asyncio
import json
import os

import boto3
from botocore.config import Config
from livekit.api import LiveKitAPI
from livekit.protocol.egress import (
    EgressStatus,
    EncodedFileOutput,
    EncodedFileType,
    EncodingOptions,
    ListEgressRequest,
    RoomCompositeEgressRequest,
    S3Upload,
    StopEgressRequest,
)


class MissionStore:
    def __init__(self):
        self.bucket = os.environ["RECORDINGS_S3_BUCKET"]
        self.write_lock = asyncio.Lock()
        self.s3 = boto3.client(
            "s3",
            region_name=os.getenv("RECORDINGS_S3_REGION", "us-east-1"),
            config=Config(
                connect_timeout=3, read_timeout=5, retries={"max_attempts": 2}
            ),
        )

    async def put(self, key, value):
        body = json.dumps(value).encode()

        def write():
            self.s3.put_object(
                Bucket=self.bucket,
                Key=key,
                Body=body,
                ContentType="application/json",
            )

        # Cancellation cannot abandon an in-flight S3 request and let its older
        # manifest overwrite a terminal write. Retain ownership until it finishes.
        async with self.write_lock:
            task = asyncio.create_task(asyncio.to_thread(write))
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                await task
                raise


def egress_wrote_file(info):
    """Whether a finished egress reports a file.

    LiveKit fills the deprecated single `file` result for a one-file room
    composite and leaves the newer `file_results` list empty -- observed on a
    real mission whose 7.7 MB recording sat in the bucket while both this
    worker and the web service called it failed. Accept either field.
    """
    if getattr(info, "file_results", None):
        return True
    return bool(getattr(getattr(info, "file", None), "filename", ""))


class MissionRecording:
    def __init__(self, room, prefix):
        self.room = room
        self.key = prefix + "/recording.mp4"
        self.egress_id = None
        self.started_at = None
        self.status = "starting"
        self.on_started = None

    async def info(self):
        async with LiveKitAPI() as api:
            items = await api.egress.list_egress(
                ListEgressRequest(egress_id=self.egress_id)
            )
        if not items.items:
            raise RuntimeError("egress disappeared")
        return items.items[0]

    async def start(self):
        async with LiveKitAPI() as api:
            info = await api.egress.start_room_composite_egress(
                RoomCompositeEgressRequest(
                    room_name=self.room,
                    layout="grid",
                    file_outputs=[
                        EncodedFileOutput(
                            file_type=EncodedFileType.MP4,
                            filepath=self.key,
                            # The bucket holds two objects per mission: this
                            # file and the worker's manifest. LiveKit's own
                            # egress manifest would be a third.
                            disable_manifest=True,
                            s3=S3Upload(
                                bucket=os.environ["RECORDINGS_S3_BUCKET"],
                                region=os.getenv("RECORDINGS_S3_REGION", "us-east-1"),
                                access_key=os.environ["AWS_ACCESS_KEY_ID"],
                                secret=os.environ["AWS_SECRET_ACCESS_KEY"],
                            ),
                        )
                    ],
                    # Bitrate in kbps. The phone publishes the glasses track at up to
                    # 4 Mbps (LiveKitSession.swift); this hop re-encodes it, so it
                    # must not be the narrower of the two or it discards detail the
                    # phone paid to send. Keep this at or above the phone's cap.
                    advanced=EncodingOptions(
                        width=720,
                        height=1280,
                        framerate=24,
                        video_bitrate=4000,
                        audio_bitrate=128,
                    ),
                )
            )
        self.egress_id = info.egress_id
        if self.on_started:
            await self.on_started()
        async with asyncio.timeout(35):
            while info.status == EgressStatus.EGRESS_STARTING:
                await asyncio.sleep(0.5)
                info = await self.info()
            if info.status != EgressStatus.EGRESS_ACTIVE:
                raise RuntimeError("recorder failed to become active")
        self.started_at = info.started_at // 1_000_000
        self.status = "recording"

    async def check(self):
        if not self.egress_id:
            return self.status
        info = await self.info()
        if info.status != EgressStatus.EGRESS_ACTIVE:
            self.status = "failed"
        return self.status

    async def stop(self):
        if not self.egress_id:
            return
        self.status = "finalizing"
        info = await self.info()
        if info.status in (EgressStatus.EGRESS_STARTING, EgressStatus.EGRESS_ACTIVE):
            async with LiveKitAPI() as api:
                info = await api.egress.stop_egress(
                    StopEgressRequest(egress_id=self.egress_id)
                )
        async with asyncio.timeout(60):
            while info.status in (
                EgressStatus.EGRESS_STARTING,
                EgressStatus.EGRESS_ACTIVE,
                EgressStatus.EGRESS_ENDING,
            ):
                await asyncio.sleep(1)
                info = await self.info()
        self.status = (
            "saved"
            if info.status == EgressStatus.EGRESS_COMPLETE and egress_wrote_file(info)
            else "failed"
        )
