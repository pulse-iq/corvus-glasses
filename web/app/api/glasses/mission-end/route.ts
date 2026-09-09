export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

import {
  authorize,
  endMission,
  missionFailure,
  MissionError
} from '@/utils/glasses/mission';
export async function POST(request: Request) {
  try {
    const owner = authorize(request);
    const body = await request.json();
    const reason = body.reason ?? 'user_ended';
    if (typeof reason !== 'string' || !/^[a-z_]{1,64}$/.test(reason))
      throw new MissionError('Invalid end reason', 400);
    return Response.json(await endMission(owner, body.missionId, reason));
  } catch (error) {
    return missionFailure(error);
  }
}
