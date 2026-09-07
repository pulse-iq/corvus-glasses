export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

import { NextResponse } from 'next/server';

/**
 * Reachability probe for the Corvus glasses app.
 *
 * The app's Settings screen needs a cheap route that proves two things at once:
 * that this server is reachable, and that the token the phone holds is the one
 * it expects. It previously probed the upstream gateway's /apps route, which
 * does not exist here -- so a perfectly working setup reported "Server error
 * 404" and looked broken while interviews ran fine.
 *
 * Deliberately token-gated rather than open: a 200 that does not depend on the
 * token would report healthy right up until the first interview failed to mint
 * a room.
 */
export async function GET(request: Request) {
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

  return NextResponse.json({ ok: true, service: 'corvus-glasses' });
}
