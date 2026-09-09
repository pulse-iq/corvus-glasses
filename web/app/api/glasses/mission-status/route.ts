export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

import {
  authorize,
  missionStatus,
  missionFailure
} from '@/utils/glasses/mission';
export async function GET(request: Request) {
  try {
    const owner = authorize(request);
    const query = new URL(request.url).searchParams;
    return Response.json(
      await missionStatus(owner, query.get('missionId') ?? ''),
      { headers: { 'Cache-Control': 'no-store' } }
    );
  } catch (error) {
    return missionFailure(error);
  }
}
