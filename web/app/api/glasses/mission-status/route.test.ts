import { afterEach, expect, it, vi } from 'vitest';
import { GET } from './route';
import { POST } from '../mission-end/route';
afterEach(() => vi.unstubAllEnvs());
it('status and end reject missing authorization before reading storage', async () => {
  vi.stubEnv('CORVUS_GLASSES_TOKEN', 'secret');
  expect(
    (
      await GET(
        new Request('https://test/api/glasses/mission-status?missionId=bad')
      )
    ).status
  ).toBe(401);
  expect(
    (
      await POST(
        new Request('https://test/api/glasses/mission-end', {
          method: 'POST',
          body: '{}'
        })
      )
    ).status
  ).toBe(401);
});
it('authorized status rejects path injection at HTTP boundary', async () => {
  vi.stubEnv('CORVUS_GLASSES_TOKEN', 'secret');
  const response = await GET(
    new Request('https://test/api/glasses/mission-status?missionId=../other', {
      headers: { Authorization: 'Bearer secret' }
    })
  );
  expect(response.status).toBe(400);
});
