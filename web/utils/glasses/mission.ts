import { createHash } from 'node:crypto';
import { Redis } from '@upstash/redis';
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import {
  AccessToken,
  AgentDispatchClient,
  EgressClient,
  RoomServiceClient
} from 'livekit-server-sdk';

export const AGENT_NAME = 'corvus-glasses';
export class MissionError extends Error {
  constructor(
    message: string,
    public status = 409
  ) {
    super(message);
  }
}
export function uuid(value: unknown): string {
  if (
    typeof value !== 'string' ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value
    )
  )
    throw new MissionError('Invalid mission identifier', 400);
  return value.toLowerCase();
}
export function validateMission(input: Record<string, unknown>) {
  if (input.mode !== 'mission' || input.version !== 1)
    throw new MissionError('Unsupported mission version', 400);
  if (
    typeof input.studyId !== 'string' ||
    !input.studyId ||
    input.studyId.length > 200
  )
    throw new MissionError('Invalid studyId', 400);
  if (
    typeof input.sessionId !== 'string' ||
    !/^[a-zA-Z0-9._:-]{1,200}$/.test(input.sessionId)
  )
    throw new MissionError('Invalid sessionId', 400);
  return {
    mode: 'mission' as const,
    version: 1,
    missionId: uuid(input.missionId),
    segmentId: uuid(input.segmentId),
    sessionId: input.sessionId,
    studyId: input.studyId
  };
}
type Mission = ReturnType<typeof validateMission>;
type Registry = {
  mission: Mission;
  engine: string;
  room: string;
  phoneIdentity: string;
  state: 'allocating' | 'ready' | 'failed';
  createdAtMs: number;
  watchdogRunId?: string;
};
const key = (owner: string, id: string) => `corvus:mission:v1:${owner}:${id}`;
export function ownerScope(secret: string) {
  return createHash('sha256').update(secret).digest('hex');
}
export function authorize(request: Request) {
  const expected = process.env.CORVUS_GLASSES_TOKEN;
  if (!expected)
    throw new MissionError('Mission authentication unavailable', 503);
  if (
    request.headers.get('authorization')?.replace(/^Bearer /i, '') !== expected
  )
    throw new MissionError('Invalid or missing token', 401);
  return ownerScope(expected);
}
function clients() {
  const url = process.env.CORVUS_LIVEKIT_URL ?? process.env.LIVEKIT_URL;
  const apiKey =
    process.env.CORVUS_LIVEKIT_API_KEY ?? process.env.LIVEKIT_API_KEY;
  const secret =
    process.env.CORVUS_LIVEKIT_API_SECRET ?? process.env.LIVEKIT_API_SECRET;
  if (!url || !apiKey || !secret || !process.env.RECORDINGS_S3_BUCKET)
    throw new MissionError('Mission service configuration missing', 503);
  const host = url.replace(/^ws/i, 'http');
  return {
    url,
    apiKey,
    secret,
    room: new RoomServiceClient(host, apiKey, secret),
    dispatch: new AgentDispatchClient(host, apiKey, secret),
    egress: new EgressClient(host, apiKey, secret)
  };
}
export async function claimMission(
  redis: Redis,
  owner: string,
  mission: Mission,
  engine: string
) {
  // Deliberately no expiry: uncertain allocation fails closed, never creates a competing worker.
  const record: Registry = {
    mission,
    engine,
    room: `corvus-mission-${mission.missionId}`,
    phoneIdentity: `corvus-phone-${mission.missionId}`,
    state: 'allocating',
    createdAtMs: Date.now()
  };
  return (
    (await redis.set(key(owner, mission.missionId), record, { nx: true })) ===
    'OK'
  );
}
async function readObject(
  objectKey: string
): Promise<Record<string, any> | null> {
  const s3 = new S3Client({
    region:
      process.env.RECORDINGS_S3_REGION ?? process.env.AWS_REGION ?? 'us-east-1'
  });
  try {
    const object = await s3.send(
      new GetObjectCommand({
        Bucket: process.env.RECORDINGS_S3_BUCKET,
        Key: objectKey
      })
    );
    if ((object.ContentLength ?? 0) > 2_000_000)
      throw new MissionError('Mission artifact too large', 502);
    const text = await object.Body?.transformToString();
    return text ? JSON.parse(text) : null;
  } catch (error) {
    if ((error as { name?: string }).name === 'NoSuchKey') return null;
    throw error;
  }
}
export function reconcileRecording(info: {
  status: number;
  fileResults?: unknown[];
}) {
  if (info.status === 3) return info.fileResults?.length ? 'saved' : 'failed';
  if (info.status >= 4) return 'failed';
  if (info.status === 2) return 'finalizing';
  return info.status === 1 ? 'recording' : 'starting';
}
async function manifest(record: Registry) {
  return readObject(
    `hack/missions/${record.mission.missionId}/segments/${record.mission.segmentId}/manifest.json`
  );
}
export async function missionTicket(
  input: Record<string, unknown>,
  engine: string,
  owner: string
) {
  const mission = validateMission(input);
  const redis = Redis.fromEnv();
  const c = clients();
  const registryKey = key(owner, mission.missionId);
  if (await redis.get(`${registryKey}:ended`))
    throw new MissionError('Mission already ended');
  const won = await claimMission(redis, owner, mission, engine);
  const record = await redis.get<Registry>(registryKey);
  if (!record) throw new MissionError('Mission allocation unavailable', 503);
  if (
    JSON.stringify(record.mission) !== JSON.stringify(mission) ||
    record.engine !== engine
  )
    throw new MissionError('Mission configuration is immutable');
  const saved = await manifest(record);
  if (!won && Date.now() - record.createdAtMs > 45_000) {
    const participants = await c.room.listParticipants(record.room);
    if (
      !participants.some(
        (p) => p.identity === `corvus-mission-agent-${mission.missionId}`
      )
    ) {
      await endMission(owner, mission.missionId);
      throw new MissionError('Mission worker unavailable');
    }
  }
  if (
    (saved?.deadlineMs && Date.now() >= saved.deadlineMs) ||
    ['ended', 'failed'].includes(saved?.phase)
  ) {
    await endMission(owner, mission.missionId);
    throw new MissionError('Mission already ended');
  }
  const metadata = JSON.stringify({
    engine,
    corvus: {
      ...mission,
      phoneIdentity: record.phoneIdentity,
      workerIdentity: `corvus-mission-agent-${mission.missionId}`
    }
  });
  if (won) {
    try {
      const { startMissionWatchdog } = await import('./mission-trigger');
      record.watchdogRunId = await startMissionWatchdog(
        owner,
        mission.missionId
      );
      await redis.set(registryKey, record);
      if (await redis.get(`${registryKey}:ended`))
        throw new MissionError('Mission already ended');
      await c.room.createRoom({
        name: record.room,
        metadata,
        emptyTimeout: 60,
        maxParticipants: 3
      });
      if (await redis.get(`${registryKey}:ended`))
        throw new MissionError('Mission already ended');
      await c.dispatch.createDispatch(record.room, AGENT_NAME, { metadata });
      record.state = 'ready';
      await redis.set(registryKey, record);
    } catch (error) {
      record.state = 'failed';
      await redis.set(registryKey, record);
      await endMission(owner, mission.missionId).catch(() => {});
      throw error;
    }
  } else if (record.state !== 'ready')
    throw new MissionError(
      'Mission allocation unresolved; start a new mission'
    );
  if (await redis.get(`${registryKey}:ended`)) {
    await endMission(owner, mission.missionId);
    throw new MissionError('Mission already ended');
  }
  const token = new AccessToken(c.apiKey, c.secret, {
    identity: record.phoneIdentity,
    ttl: '30m'
  });
  token.metadata = metadata;
  token.addGrant({
    roomJoin: true,
    room: record.room,
    canPublish: true,
    canSubscribe: true,
    canPublishData: true
  });
  const jwt = await token.toJwt();
  if (await redis.get(`${registryKey}:ended`)) {
    await endMission(owner, mission.missionId);
    throw new MissionError('Mission already ended');
  }
  return {
    url: c.url,
    room: record.room,
    token: jwt,
    missionVersion: 1,
    agentName: AGENT_NAME,
    workerIdentity: `corvus-mission-agent-${mission.missionId}`,
    phoneIdentity: record.phoneIdentity,
    missionId: mission.missionId,
    segmentId: mission.segmentId
  };
}
export async function missionStatus(
  owner: string,
  missionId: string,
  interceptId?: string | null
): Promise<Record<string, any>> {
  const id = uuid(missionId);
  const redis = Redis.fromEnv();
  const registryKey = key(owner, id);
  const record = await redis.get<Registry>(registryKey);
  if (!record) throw new MissionError('Mission not found', 404);
  if (interceptId) {
    const result = await readObject(
      `hack/missions/${id}/segments/${record.mission.segmentId}/interviews/${uuid(interceptId)}.json`
    );
    if (!result) throw new MissionError('Result not found', 404);
    return result;
  }
  const cached = await redis.get<Record<string, any>>(`${registryKey}:status`);
  const saved = (await manifest(record)) ?? cached;
  const terminal = await redis.get<{ endedAtMs: number }>(
    `${registryKey}:ended`
  );
  const c = clients();
  const egress = await c.egress.listEgress({ roomName: record.room });
  const info = egress.find((e) => e.egressId === saved?.egressId) ?? egress[0];
  if (!terminal && saved?.phase !== 'ended') {
    if (saved?.deadlineMs && Date.now() >= saved.deadlineMs)
      return endMission(owner, id, 'mission_time_limit');
    if (Date.now() - record.createdAtMs > 45_000) {
      const participants = await c.room.listParticipants(record.room);
      if (
        !participants.some((p) => p.identity === `corvus-mission-agent-${id}`)
      )
        return endMission(owner, id, 'worker_unavailable');
    }
  }

  const status = {
    ...saved,
    ...(!info &&
    cached &&
    cached.egressId === saved?.egressId &&
    ['saved', 'failed'].includes(cached?.recordingStatus)
      ? { recordingStatus: cached.recordingStatus }
      : {}),
    missionId: id,
    segmentId: record.mission.segmentId,
    phase: terminal
      ? 'ended'
      : (saved?.phase ?? (record.state === 'failed' ? 'ended' : 'starting')),
    ...(record.state === 'failed' ? { endedBecause: 'allocation_failed' } : {}),
    ...(info
      ? { recordingStatus: reconcileRecording(info), egressId: info.egressId }
      : {})
  };
  // Durable reconciliation is separate from the worker-owned manifest; stale worker writes cannot erase termination.
  await redis.set(`${registryKey}:status`, status);
  if (
    (saved?.phase === 'ended' ||
      (terminal && Date.now() - terminal.endedAtMs > 45_000)) &&
    !egress.some((e) => e.status <= 2)
  )
    await c.room.deleteRoom(record.room).catch(() => {});
  return status;
}
export async function endMission(
  owner: string,
  missionId: string,
  reason = 'user_ended'
): Promise<Record<string, any>> {
  const id = uuid(missionId);
  const redis = Redis.fromEnv();
  const registryKey = key(owner, id);
  // Must precede any room/registry lookup: End can beat token allocation entirely.
  await redis.set(
    `${registryKey}:ended`,
    { endedAtMs: Date.now(), reason },
    { nx: true }
  );
  const ended = await redis.get<{ reason: string }>(`${registryKey}:ended`);
  const record = await redis.get<Registry>(registryKey);
  if (!record) return { missionId: id, phase: 'ended' };
  const c = clients();
  // The phone stops capture immediately. Keep the worker connected to persist
  // partial transcripts; the signed room metadata is its fallback end signal.
  const notFound = (error: unknown) => {
    const e = error as { code?: string; status?: number };
    if (e.code !== 'not_found' && e.status !== 404) throw error;
  };
  await c.room
    .updateRoomMetadata(
      record.room,
      JSON.stringify({
        engine: record.engine,
        corvus: {
          ...record.mission,
          phoneIdentity: record.phoneIdentity,
          workerIdentity: `corvus-mission-agent-${id}`,
          missionEndRequested: true,
          missionEndReason: ended?.reason ?? reason
        }
      })
    )
    .catch(notFound);
  await c.room
    .removeParticipant(record.room, record.phoneIdentity)
    .catch(notFound);
  const egress = await c.egress.listEgress({ roomName: record.room });
  await Promise.all(
    egress
      .filter((e) => e.status < 2)
      .map((e) => c.egress.stopEgress(e.egressId))
  );
  return missionStatus(owner, id);
}
export function missionFailure(error: unknown) {
  return Response.json(
    {
      error:
        error instanceof MissionError
          ? error.message
          : 'Mission service unavailable'
    },
    { status: error instanceof MissionError ? error.status : 503 }
  );
}

/** Node-side watchdog step, separately testable without the Workflow runtime. */
export async function missionWatchdogTick(owner: string, missionId: string) {
  const id = uuid(missionId);
  const redis = Redis.fromEnv();
  const registryKey = key(owner, id);
  const record = await redis.get<Registry>(registryKey);
  if (!record) return { done: true, nextAtMs: Date.now() };
  const saved = await manifest(record);
  const terminal = await redis.get(`${registryKey}:ended`);
  const deadline =
    typeof saved?.deadlineMs === 'number'
      ? saved.deadlineMs
      : record.createdAtMs + 45_000;
  if (!terminal && Date.now() >= deadline)
    await endMission(
      owner,
      id,
      saved?.deadlineMs ? 'mission_time_limit' : 'setup_timeout'
    );
  const status = await missionStatus(owner, id);
  const recordingStatus = status.recordingStatus;
  const done =
    status.phase === 'ended' &&
    (recordingStatus === 'saved' ||
      recordingStatus === 'failed' ||
      !status.egressId);
  return {
    done,
    nextAtMs: Math.max(
      Date.now() + 100,
      Math.min(
        Date.now() + 10_000,
        deadline > Date.now() ? deadline : Date.now() + 10_000
      )
    )
  };
}
