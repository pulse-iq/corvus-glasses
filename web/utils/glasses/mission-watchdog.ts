import { sleep } from 'workflow';
import { missionWatchdogTick } from './mission';

/** Enqueued before room creation: survives phone, worker and route-process loss. */
export async function missionWatchdog(owner: string, missionId: string) {
  'use workflow';
  for (;;) {
    try {
      const next = await reconcileMissionStep(owner, missionId);
      if (next.done) return;
      await sleep(new Date(next.nextAtMs));
    } catch {
      // Keep the safety owner alive through extended dependency outages. Step
      // retry failures are visible in Workflow logs; subsequent steps retry cleanup.
      console.warn('[mission-watchdog] dependency unavailable', { missionId });
      await sleep('10s');
    }
  }
}

export async function reconcileMissionStep(owner: string, missionId: string) {
  'use step';
  console.info('[mission-watchdog] reconcile', { missionId });
  return missionWatchdogTick(owner, missionId);
}
reconcileMissionStep.maxRetries = 20;
