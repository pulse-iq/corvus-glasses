import { describe, expect, it } from 'vitest';
import { validateMission, claimMission, reconcileRecording } from './mission';
const id = '12345678-1234-4234-8234-123456789abc';
const request = {
  mode: 'mission',
  version: 1,
  missionId: id,
  segmentId: id,
  sessionId: id,
  studyId: 'study'
};
describe('mission production boundary', () => {
  it('rejects unsupported protocol and path identifiers', () => {
    expect(() => validateMission({ ...request, version: 2 })).toThrow();
    expect(() =>
      validateMission({ ...request, missionId: '../escape' })
    ).toThrow();
  });
  it('forwards the conversation mode and defaults it to realtime', () => {
    expect(validateMission(request).conversation).toBe('realtime');
    expect(
      validateMission({ ...request, conversation: 'turnBased' }).conversation
    ).toBe('turnBased');
    expect(() =>
      validateMission({ ...request, conversation: 'scripted' })
    ).toThrow();
  });
  it('one durable claim wins concurrent starts; subsequent start cannot allocate', async () => {
    const data = new Map();
    const redis = {
      set: async (k: string, v: unknown) => {
        if (data.has(k)) return null;
        data.set(k, v);
        return 'OK';
      }
    };
    const wins = await Promise.all(
      Array.from({ length: 10 }, () =>
        claimMission(
          redis as never,
          'owner',
          validateMission(request),
          'gemini'
        )
      )
    );
    expect(wins.filter(Boolean)).toHaveLength(1);
  });
  it('accepted stop and ending are not saved', () => {
    expect(reconcileRecording({ status: 2, fileResults: [] })).toBe(
      'finalizing'
    );
    expect(reconcileRecording({ status: 3, fileResults: [] })).toBe('failed');
    expect(
      reconcileRecording({
        status: 3,
        fileResults: [],
        result: { case: 'file' }
      })
    ).toBe('saved');
    expect(
      reconcileRecording({ status: 3, fileResults: [{ filename: 'key' }] })
    ).toBe('saved');
    expect(reconcileRecording({ status: 5, fileResults: [] })).toBe('failed');
  });
});
