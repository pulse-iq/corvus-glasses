import { afterEach, expect, it, vi } from 'vitest';
import { GET } from './route';

afterEach(() => vi.unstubAllEnvs());
it('fails closed until this deployment has its own shared token', async () => {
  vi.stubEnv('CORVUS_GLASSES_TOKEN', '');
  expect((await GET(new Request('https://glasses.test/api/glasses/health'))).status).toBe(503);
});
it('rejects an invalid token', async () => {
  vi.stubEnv('CORVUS_GLASSES_TOKEN', 'test-secret');
  const response = await GET(new Request('https://glasses.test/api/glasses/health', {
    headers: { Authorization: 'Bearer wrong' }
  }));
  expect(response.status).toBe(401);
});
it('identifies the standalone service after authentication', async () => {
  vi.stubEnv('CORVUS_GLASSES_TOKEN', 'test-secret');
  const response = await GET(new Request('https://glasses.test/api/glasses/health', {
    headers: { Authorization: 'Bearer test-secret' }
  }));
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ ok: true, service: 'corvus-glasses' });
});
