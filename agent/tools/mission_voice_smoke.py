"""Synthetic LiveKit/Gemini smoke test; creates and deletes one temporary room.

Run from the repository with configured LIVEKIT_* / GOOGLE_API_KEY environment:
    PYTHONPATH=agent python agent/tools/mission_voice_smoke.py
Optional --env-file requires python-dotenv in the test environment. No microphone,
camera, egress, deployment, or real shopper data is used. This incurs API usage.
"""

import argparse
import asyncio
import json
import os
import time
from uuid import uuid4

from livekit import api, rtc

from corvus_mission_voice import MissionVoice
from main import build_llm


async def run():
    room_name = "codex-mission-probe-" + str(uuid4())
    client = api.LiveKitAPI()
    phone, worker = rtc.Room(), rtc.Room()
    voice = None
    tasks = []
    created = False
    audible_frames = 0
    connections = 0

    async def receive(track):
        nonlocal audible_frames
        stream = rtc.AudioStream(track)
        try:
            async for event in stream:
                # The SDK emits silence while idle; packets alone prove nothing.
                if max((abs(sample) for sample in event.frame.data), default=0) > 300:
                    audible_frames += 1
        finally:
            await stream.aclose()

    @phone.on("track_subscribed")
    def subscribed(track, publication, participant):
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            tasks.append(asyncio.create_task(receive(track)))

    def token(identity):
        return (
            api.AccessToken(os.environ["LIVEKIT_API_KEY"], os.environ["LIVEKIT_API_SECRET"])
            .with_identity(identity)
            .with_grants(api.VideoGrants(room_join=True, room=room_name))
            .to_jwt()
        )

    def model():
        nonlocal connections
        connections += 1
        return build_llm("gemini", silent_tools=True)

    try:
        await client.room.create_room(api.CreateRoomRequest(name=room_name, empty_timeout=120))
        created = True
        await phone.connect(os.environ["LIVEKIT_URL"], token("synthetic-phone"))
        await worker.connect(os.environ["LIVEKIT_URL"], token("synthetic-worker"))
        source = rtc.AudioSource(48000, 1)
        track = rtc.LocalAudioTrack.create_audio_track("synthetic-silence", source)
        await phone.local_participant.publish_track(
            track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        )

        async def silence():
            while True:
                await source.capture_frame(rtc.AudioFrame(bytes(960 * 2), 48000, 1, 960))
                await asyncio.sleep(0.02)

        tasks.append(asyncio.create_task(silence()))
        voice = MissionVoice(worker, "synthetic-phone", model)
        await asyncio.wait_for(voice.prepare(), 30)
        await asyncio.wait_for(voice.greet("Your mission has started."), 20)
        if not audible_frames:
            raise AssertionError("Welcome had no audible audio")
        print(json.dumps({"step": "welcome", "audibleFrames": audible_frames}), flush=True)
        for product in ("milk", "bread", "coffee"):
            await asyncio.wait_for(voice.prepare(), 30)
            if len(worker.local_participant.track_publications) != 1:
                raise AssertionError("Prepared session leaked or omitted an audio track")
            before, prepared_connections = audible_frames, connections
            question = f"What made you choose that {product}?"
            start = time.monotonic()
            interview = asyncio.create_task(voice.interview({
                "instructions": f"Ask exactly: {question} Then wait silently for an answer.",
                "openingQuestion": question,
            }, str(uuid4())))
            tasks.append(interview)
            while audible_frames <= before and time.monotonic() - start < 15:
                await asyncio.sleep(0.025)
            onset = time.monotonic() - start
            if audible_frames <= before:
                raise AssertionError(f"No audible opening question for {product}")
            await asyncio.sleep(3)
            await voice.interrupt("probe_complete")
            result = await asyncio.wait_for(interview, 5)
            if connections != prepared_connections:
                raise AssertionError("Beginning interview allocated a model connection")
            if not any(product in turn["text"].lower() for turn in result["turns"]):
                raise AssertionError(f"Transcript did not reflect {product} brief")
            print(json.dumps({"step": "interview", "product": product,
                              "firstAudibleSeconds": round(onset, 3),
                              "modelConnections": connections,
                              "turns": result["turns"]}), flush=True)
        await voice.close()
        if worker.local_participant.track_publications:
            raise AssertionError("Voice close left published tracks")
        print("PASS: welcome and three prepared interviews in one room", flush=True)
    finally:
        try:
            if voice:
                await asyncio.wait_for(voice.close(), 10)
        finally:
            for task in tasks:
                task.cancel()
            results = await asyncio.gather(*tasks, return_exceptions=True)
            for result in results:
                if isinstance(result, Exception):
                    print("background task error:", type(result).__name__, flush=True)
            try:
                await phone.disconnect()
                await worker.disconnect()
            finally:
                try:
                    if created:
                        await client.room.delete_room(api.DeleteRoomRequest(room=room_name))
                        print("Temporary room deleted", flush=True)
                finally:
                    await client.aclose()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file")
    args = parser.parse_args()
    if args.env_file:
        from dotenv import load_dotenv

        load_dotenv(args.env_file)
    asyncio.run(run())
