import { beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('./mission-trigger', () => ({
  startMissionWatchdog: (...args: unknown[]) => f.startWatchdog(...args)
}));
const f = vi.hoisted(() => ({
  data: new Map<string, any>(),
  startWatchdog: vi.fn(),
  createRoom: vi.fn(),
  createDispatch: vi.fn(),
  deleteRoom: vi.fn(),
  listParticipants: vi.fn(),
  listEgress: vi.fn(),
  stopEgress: vi.fn(),
  removeParticipant: vi.fn(),
  updateRoomMetadata: vi.fn(),
  object: vi.fn(),
  jwt: vi.fn()
}));
vi.mock('@upstash/redis', () => ({
  Redis: {
    fromEnv: () => ({
      get: async (k: string) => f.data.get(k),
      set: async (k: string, v: any, opts?: { nx?: boolean }) => {
        if (opts?.nx && f.data.has(k)) return null;
        f.data.set(k, structuredClone(v));
        return 'OK';
      }
    })
  }
}));
vi.mock('@aws-sdk/client-s3', () => ({
  S3Client: class {
    send = f.object;
  },
  GetObjectCommand: class {
    constructor(public input: any) {}
  }
}));
vi.mock('livekit-server-sdk', () => ({
  AccessToken: class {
    metadata = '';
    addGrant() {}
    toJwt = f.jwt;
  },
  RoomServiceClient: class {
    createRoom = f.createRoom;
    deleteRoom = f.deleteRoom;
    listParticipants = f.listParticipants;
    removeParticipant = f.removeParticipant;
    updateRoomMetadata = f.updateRoomMetadata;
  },
  AgentDispatchClient: class {
    createDispatch = f.createDispatch;
  },
  EgressClient: class {
    listEgress = f.listEgress;
    stopEgress = f.stopEgress;
  }
}));
import {
  missionTicket,
  endMission,
  missionStatus,
  missionWatchdogTick
} from './mission';
const id = '12345678-1234-4234-8234-123456789abc';
const input = {
  mode: 'mission',
  version: 1,
  missionId: id,
  segmentId: id,
  sessionId: id,
  studyId: 'study'
};
beforeEach(() => {
  vi.clearAllMocks();
  f.data.clear();
  f.startWatchdog.mockResolvedValue('durable-run');
  Object.assign(process.env, {
    CORVUS_LIVEKIT_URL: 'wss://test',
    CORVUS_LIVEKIT_API_KEY: 'test',
    CORVUS_LIVEKIT_API_SECRET: 'test',
    RECORDINGS_S3_BUCKET: 'test'
  });
  f.object.mockRejectedValue(Object.assign(new Error(), { name: 'NoSuchKey' }));
  f.createRoom.mockResolvedValue({});
  f.createDispatch.mockResolvedValue({});
  f.deleteRoom.mockResolvedValue({});
  f.removeParticipant.mockResolvedValue({});
  f.updateRoomMetadata.mockResolvedValue({});
  f.listParticipants.mockResolvedValue([]);
  f.listEgress.mockResolvedValue([]);
  f.jwt.mockResolvedValue('token');
});
describe('durable mission lifecycle', () => {
  it('requires durable watchdog registration before creating any room', async () => {
    f.startWatchdog.mockRejectedValueOnce(new Error('queue unavailable'));
    await expect(missionTicket(input, 'gemini', 'owner')).rejects.toThrow(
      'queue unavailable'
    );
    expect(f.createRoom).not.toHaveBeenCalled();
    expect(f.createDispatch).not.toHaveBeenCalled();
  });
  it('repeated tickets reuse the room, identity and one dispatch', async () => {
    const first = await missionTicket(input, 'gemini', 'owner');
    const second = await missionTicket(input, 'gemini', 'owner');
    expect(first.room).toBe(second.room);
    expect(first.workerIdentity).toBe(`corvus-mission-agent-${id}`);
    expect(f.createDispatch).toHaveBeenCalledTimes(1);
  });
  it('End before token allocation permanently rejects resurrection', async () => {
    await endMission('owner', id);
    await expect(missionTicket(input, 'gemini', 'owner')).rejects.toThrow(
      'ended'
    );
    expect(f.createRoom).not.toHaveBeenCalled();
  });
  it('End during dispatch discards the late token and deletes the late room', async () => {
    f.createDispatch.mockImplementationOnce(async () => {
      await endMission('owner', id);
      return {};
    });
    await expect(missionTicket(input, 'gemini', 'owner')).rejects.toThrow(
      'ended'
    );
    expect(f.jwt).not.toHaveBeenCalled();
    expect(f.updateRoomMetadata).toHaveBeenCalled();
  });
  it('End during JWT signing cannot return a resurrected ticket', async () => {
    f.jwt.mockImplementationOnce(async () => {
      await endMission('owner', id);
      return 'late';
    });
    await expect(missionTicket(input, 'gemini', 'owner')).rejects.toThrow(
      'ended'
    );
  });
  it('End leaves recorder participant until verified finalization', async () => {
    await missionTicket(input, 'gemini', 'owner');
    f.listParticipants.mockResolvedValue([
      { identity: `corvus-phone-${id}` },
      { identity: `corvus-mission-agent-${id}` },
      { identity: 'EG_recorder' }
    ]);
    f.listEgress.mockResolvedValue([
      { egressId: 'eg', status: 1, fileResults: [] }
    ]);
    await endMission('owner', id);
    expect(f.removeParticipant.mock.calls.map((c) => c[1])).toEqual([
      `corvus-phone-${id}`
    ]);
    expect(f.stopEgress).toHaveBeenCalledWith('eg');
    expect(f.deleteRoom).not.toHaveBeenCalled();
  });
  it('an ambiguous dispatch failure never redispatches on retry', async () => {
    f.createDispatch.mockRejectedValueOnce(new Error('timeout'));
    await expect(missionTicket(input, 'gemini', 'owner')).rejects.toThrow(
      'timeout'
    );
    await expect(missionTicket(input, 'gemini', 'owner')).rejects.toThrow(
      'ended'
    );
    expect(f.createDispatch).toHaveBeenCalledTimes(1);
  });
  it('reads final file status after worker loss without overwriting the manifest', async () => {
    await missionTicket(input, 'gemini', 'owner');
    f.object.mockResolvedValue({
      Body: {
        transformToString: async () =>
          JSON.stringify({
            phase: 'ended',
            egressId: 'eg',
            recordingStatus: 'finalizing'
          })
      }
    });
    f.listEgress.mockResolvedValue([
      { egressId: 'eg', status: 3, fileResults: [{ filename: 'movie.mp4' }] }
    ]);
    expect(await missionStatus('owner', id)).toMatchObject({
      phase: 'ended',
      recordingStatus: 'saved'
    });
    f.listEgress.mockResolvedValue([]);
    expect(await missionStatus('owner', id)).toMatchObject({
      recordingStatus: 'saved'
    });
  });
  it('durable watchdog stops an orphan at its original deadline with no HTTP caller', async () => {
    await missionTicket(input, 'gemini', 'owner');
    f.object.mockResolvedValue({
      Body: {
        transformToString: async () =>
          JSON.stringify({
            phase: 'shopping',
            deadlineMs: Date.now() - 1,
            egressId: 'eg',
            recordingStatus: 'recording'
          })
      }
    });
    f.listEgress.mockResolvedValue([
      { egressId: 'eg', status: 1, fileResults: [] }
    ]);
    const result = await missionWatchdogTick('owner', id);
    expect(result.done).toBe(false);
    expect(f.stopEgress).toHaveBeenCalledWith('eg');
    expect(
      JSON.parse(f.updateRoomMetadata.mock.calls[0][1]).corvus.missionEndReason
    ).toBe('mission_time_limit');
    f.listEgress.mockResolvedValue([
      { egressId: 'eg', status: 3, fileResults: [{ filename: 'video.mp4' }] }
    ]);
    expect((await missionWatchdogTick('owner', id)).done).toBe(true);
  });
  it('durable watchdog bounds setup when the worker never writes readiness', async () => {
    await missionTicket(input, 'gemini', 'owner');
    const entry = Array.from(f.data.entries()).find(
      ([k]) => !k.endsWith(':ended')
    )!;
    entry[1].createdAtMs = Date.now() - 46_000;
    expect((await missionWatchdogTick('owner', id)).done).toBe(true);
    expect(
      JSON.parse(f.updateRoomMetadata.mock.calls[0][1]).corvus.missionEndReason
    ).toBe('setup_timeout');
  });
  it('rejects changed frozen config and ownership', async () => {
    await missionTicket(input, 'gemini', 'owner');
    await expect(missionTicket(input, 'openai', 'owner')).rejects.toThrow(
      'immutable'
    );
    await expect(missionStatus('other', id)).rejects.toThrow('not found');
  });
});
