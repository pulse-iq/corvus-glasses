import { start } from 'workflow/api';
import { missionWatchdog } from './mission-watchdog';
export async function startMissionWatchdog(owner: string, missionId: string) {
  const run = await start(missionWatchdog, [owner, missionId]);
  return run.runId;
}
