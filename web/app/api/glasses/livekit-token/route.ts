export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

import { randomUUID } from 'node:crypto';
import {
  missionTicket,
  missionFailure,
  ownerScope
} from '@/utils/glasses/mission';

import {
  AccessToken,
  AgentDispatchClient,
  RoomServiceClient
} from 'livekit-server-sdk';
import { NextResponse } from 'next/server';

/**
 * Room ticket for the Corvus glasses app.
 *
 * The phone runs Stage 1 and the turn-based Stage 2 entirely on its own, so
 * this is the only server it ever needs: a LiveKit room token has to be signed
 * with the API secret, and that secret must not ship inside an iOS binary.
 *
 * The interview's instructions arrive already written. The glasses app builds
 * them from the study it is running, and this route only forwards them, so the
 * study stays the single definition of how Corvus interviews rather than being
 * split between a phone and a Python worker.
 */

type GlassesTokenRequest = {
  engine?: string;
  corvus?: Record<string, unknown>;
};

/** The worker registers this name; dispatch explicitly into this room only. */
const AGENT_NAME = 'corvus-glasses';

export async function POST(request: Request) {
  // Shared secret, sent by the app as a bearer token. Not user auth: the
  // glasses app has no accounts, and this only exists so a locally-run dev
  // server on a laptop is not an open room-minting endpoint.
  const expected = process.env.CORVUS_GLASSES_TOKEN;
  if (!expected) {
    return NextResponse.json(
      { error: 'CORVUS_GLASSES_TOKEN is not set on this server' },
      { status: 503 }
    );
  }
  const presented = request.headers
    .get('authorization')
    ?.replace(/^Bearer /i, '');
  if (presented !== expected) {
    return NextResponse.json(
      { error: 'Invalid or missing token' },
      { status: 401 }
    );
  }

  let payload: GlassesTokenRequest = {};
  try {
    payload = (await request.json()) as GlassesTokenRequest;
  } catch (_error) {
    // The app always sends a body, but an empty one is survivable: engine has a
    // default and a missing interview brief just yields the worker's own prompt.
  }

  const livekitUrl = process.env.CORVUS_LIVEKIT_URL ?? process.env.LIVEKIT_URL;
  const apiKey =
    process.env.CORVUS_LIVEKIT_API_KEY ?? process.env.LIVEKIT_API_KEY;
  const apiSecret =
    process.env.CORVUS_LIVEKIT_API_SECRET ?? process.env.LIVEKIT_API_SECRET;

  if (!livekitUrl || !apiKey || !apiSecret) {
    return NextResponse.json({ error: 'LiveKit env missing' }, { status: 500 });
  }

  const engine = payload.engine === 'openai' ? 'openai' : 'gemini';
  const corvus = payload.corvus ?? null;

  if (corvus?.mode === 'mission') {
    try {
      return NextResponse.json(
        await missionTicket(corvus, engine, ownerScope(expected))
      );
    } catch (error) {
      return missionFailure(error);
    }
  }

  // One room per interview, never reused. Agent dispatch fires on room
  // creation, so re-entering a room that is still draining from the previous
  // interview gets no agent at all -- and on glasses that failure is silent:
  // the wearer is asked nothing and simply stands there.
  const room = `corvus-${corvus?.itemId ?? 'session'}-${randomUUID()}`;

  const metadata = JSON.stringify({
    engine,
    ...(corvus ? { corvus } : {})
  });

  const roomServiceUrl = livekitUrl
    .replace(/^wss:\/\//i, 'https://')
    .replace(/^ws:\/\//i, 'http://');

  if (AGENT_NAME) {
    const roomClient = new RoomServiceClient(roomServiceUrl, apiKey, apiSecret);
    try {
      await roomClient.createRoom({ name: room, metadata });
    } catch (error) {
      console.error('[glasses-token] createRoom failed:', error);
      return NextResponse.json(
        { error: 'Failed to create LiveKit room' },
        { status: 500 }
      );
    }

    const dispatchClient = new AgentDispatchClient(
      roomServiceUrl,
      apiKey,
      apiSecret
    );
    try {
      await dispatchClient.createDispatch(room, AGENT_NAME);
    } catch (error) {
      console.error('[glasses-token] createDispatch failed:', error);
      return NextResponse.json(
        {
          error: `Failed to dispatch '${AGENT_NAME}' — is the Corvus agent worker running?`
        },
        { status: 500 }
      );
    }
  }

  // The worker reads the brief from participant metadata, so it has to be on
  // the token as well as the room.
  const token = new AccessToken(apiKey, apiSecret, {
    identity: `corvus-glasses-${randomUUID()}`,
    ttl: '15m'
  });
  token.metadata = metadata;
  token.addGrant({
    roomJoin: true,
    room,
    canPublish: true,
    canSubscribe: true
  });

  // Key names match what the iOS client decodes: url, room, token.
  return NextResponse.json({
    url: livekitUrl,
    room,
    token: await token.toJwt()
  });
}
