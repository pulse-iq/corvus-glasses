import { createHash } from 'node:crypto';
import { Redis } from '@upstash/redis';
import {
  AccessToken,
  AgentDispatchClient,
  EgressClient,
  RoomServiceClient
} from 'livekit-server-sdk';

export const AGENT_NAME = 'corvus-glasses';
/** How long allocation may take before a missing worker means setup failed. */
const SETUP_GRACE_MS = 45_000;
/** How long after End the room is kept for the recorder to finalize. */
const TEARDOWN_GRACE_MS = 45_000;
/** How long after End the watchdog keeps waiting for a recording verdict. */
const FINALIZE_LIMIT_MS = 30 * 60_000;
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
  /** First time the worker was observed in the room. */
  workerSeenAtMs?: number;
};
const key = (owner: string, id: string) => `corvus:mission:v1:${owner}:${id}`;
const workerIdentity = (id: string) => `corvus-mission-agent-${id}`;
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
  if (!url || !apiKey || !secret)
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
export function reconcileRecording(info: {
  status: number;
  fileResults?: unknown[];
  result?: { case?: string };
}) {
  // LiveKit fills the deprecated single `file` result for a one-file room
  // composite and leaves `fileResults` empty -- observed on a real mission
  // whose recording was in the bucket while this read 'failed'. Either counts.
  const wroteFile = !!info.fileResults?.length || info.result?.case === 'file';
  if (info.status === 3) return wroteFile ? 'saved' : 'failed';
  if (info.status >= 4) return 'failed';
  if (info.status === 2) return 'finalizing';
  return info.status === 1 ? 'recording' : 'starting';
}
/**
 * Whether the worker is in the room right now. The gateway has no channel to
 * the worker other than LiveKit itself, so presence is its only view of the
 * worker's health; the phone hears the worker's own state over the room.
 */
async function workerPresent(
  c: ReturnType<typeof clients>,
  record: Registry,
  id: string
) {
  const participants = await c.room
    .listParticipants(record.room)
    .catch(() => []);
  return participants.some((p) => p.identity === workerIdentity(id));
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
  if (
    !won &&
    Date.now() - record.createdAtMs > SETUP_GRACE_MS &&
    !(await workerPresent(c, record, mission.missionId))
  ) {
    await endMission(owner, mission.missionId, 'worker_unavailable');
    throw new MissionError('Mission worker unavailable');
  }
  const metadata = JSON.stringify({
    engine,
    corvus: {
      ...mission,
      phoneIdentity: record.phoneIdentity,
      workerIdentity: workerIdentity(mission.missionId)
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
      // The empty timeout only covers a room nobody ever joined; an active
      // mission always has the phone or the worker in it. Cleanup is the
      // gateway's job, in missionStatus.
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
  // Long enough for a first join and an ordinary reconnect. A rejoin after
  // expiry simply asks for another ticket; the room and identity are reused.
  const token = new AccessToken(c.apiKey, c.secret, {
    identity: record.phoneIdentity,
    ttl: '4h'
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
    workerIdentity: workerIdentity(mission.missionId),
    phoneIdentity: record.phoneIdentity,
    missionId: mission.missionId,
    segmentId: mission.segmentId
  };
}
/**
 * Everything the gateway knows comes from its own registry and from LiveKit:
 * the worker's presence and the recorder's state. It never reads the bucket.
 * `phase` uses the phone's vocabulary: starting, shopping, ended.
 */
export async function missionStatus(
  owner: string,
  missionId: string
): Promise<Record<string, any>> {
  const id = uuid(missionId);
  const redis = Redis.fromEnv();
  const registryKey = key(owner, id);
  const record = await redis.get<Registry>(registryKey);
  if (!record) throw new MissionError('Mission not found', 404);
  const cached = await redis.get<Record<string, any>>(`${registryKey}:status`);
  const terminal = await redis.get<{ endedAtMs: number; reason: string }>(
    `${registryKey}:ended`
  );
  const c = clients();
  const egress = await c.egress.listEgress({ roomName: record.room });
  const info =
    egress.find((e) => e.egressId === cached?.egressId) ?? egress[0];
  let present = false;
  if (!terminal && record.state === 'ready') {
    present = await workerPresent(c, record, id);
    if (present && !record.workerSeenAtMs) {
      record.workerSeenAtMs = Date.now();
      await redis.set(registryKey, record);
    }
    if (!present && Date.now() - record.createdAtMs > SETUP_GRACE_MS)
      return endMission(
        owner,
        id,
        record.workerSeenAtMs ? 'worker_unavailable' : 'setup_timeout'
      );
  }
  const status = {
    missionId: id,
    segmentId: record.mission.segmentId,
    phase: terminal || record.state === 'failed'
      ? 'ended'
      : present
        ? 'shopping'
        : 'starting',
    ...(record.state === 'failed' ? { endedBecause: 'allocation_failed' } : {}),
    ...(terminal ? { endedBecause: terminal.reason, endedAtMs: terminal.endedAtMs } : {}),
    ...(info
      ? { recordingStatus: reconcileRecording(info), egressId: info.egressId }
      : cached && ['saved', 'failed'].includes(cached.recordingStatus)
        ? { recordingStatus: cached.recordingStatus, egressId: cached.egressId }
        : {})
  };
  // A verdict is kept once reached: egress history is not retained forever.
  await redis.set(`${registryKey}:status`, status);
  if (
    terminal &&
    Date.now() - terminal.endedAtMs > TEARDOWN_GRACE_MS &&
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
          workerIdentity: workerIdentity(id),
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

/**
 * Node-side watchdog step, separately testable without the Workflow runtime.
 * There is no mission time limit: a trip lasts as long as it lasts. The
 * watchdog only ends a mission whose worker has gone, and stops once the
 * recording has a verdict or has waited long enough for one.
 */
export async function missionWatchdogTick(owner: string, missionId: string) {
  const id = uuid(missionId);
  const redis = Redis.fromEnv();
  const registryKey = key(owner, id);
  const record = await redis.get<Registry>(registryKey);
  if (!record) return { done: true, nextAtMs: Date.now() };
  const status = await missionStatus(owner, id);
  const terminal = await redis.get<{ endedAtMs: number }>(
    `${registryKey}:ended`
  );
  const settled =
    status.recordingStatus === 'saved' ||
    status.recordingStatus === 'failed' ||
    !status.egressId;
  const done =
    status.phase === 'ended' &&
    (settled ||
      (terminal !== null &&
        terminal !== undefined &&
        Date.now() - terminal.endedAtMs > FINALIZE_LIMIT_MS));
  // Quick while something is settling, slow across a long quiet trip.
  const interval =
    status.phase === 'ended' || status.phase === 'starting' ? 10_000 : 60_000;
  return { done, nextAtMs: Date.now() + interval };
}
