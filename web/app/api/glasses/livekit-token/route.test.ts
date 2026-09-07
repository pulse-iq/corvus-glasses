import { afterEach, beforeEach, expect, it, vi } from 'vitest';
const mocks = vi.hoisted(() => ({
  mission: vi.fn(), room: vi.fn(), dispatch: vi.fn(), grant: vi.fn()
}));
vi.mock('@/utils/glasses/mission', () => ({
  missionTicket: mocks.mission,
  ownerScope: (token: string) => `owner:${token}`,
  missionFailure: () => Response.json({ error: 'mission failed' }, { status: 503 })
}));
vi.mock('livekit-server-sdk', () => ({
  RoomServiceClient: class { createRoom = mocks.room; },
  AgentDispatchClient: class { createDispatch = mocks.dispatch; },
  AccessToken: class {
    addGrant = mocks.grant;
    async toJwt() { return 'signed-test-ticket'; }
  }
}));
import { POST } from './route';
beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv('CORVUS_GLASSES_TOKEN', 'test-secret');
  vi.stubEnv('CORVUS_LIVEKIT_URL', 'wss://glasses.test');
  vi.stubEnv('CORVUS_LIVEKIT_API_KEY', 'test-key');
  vi.stubEnv('CORVUS_LIVEKIT_API_SECRET', 'test-api-secret');
});
afterEach(() => vi.unstubAllEnvs());
function request(body: unknown, token = 'test-secret') {
  return new Request('https://glasses.test/api/glasses/livekit-token', {
    method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body)
  });
}
it('rejects unauthorized requests before allocating rooms', async () => {
  expect((await POST(request({}, 'wrong'))).status).toBe(401);
  expect(mocks.mission).not.toHaveBeenCalled();
  expect(mocks.room).not.toHaveBeenCalled();
});
it('passes mission configuration to the durable allocation service', async () => {
  const corvus = { mode: 'mission', version: 1, missionId: 'mission' };
  const ticket = { url: 'wss://glasses.test', room: 'mission-room', token: 'signed', missionVersion: 1 };
  mocks.mission.mockResolvedValue(ticket);
  const response = await POST(request({ engine: 'openai', corvus }));
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(ticket);
  expect(mocks.mission).toHaveBeenCalledWith(corvus, 'openai', 'owner:test-secret');
  expect(mocks.room).not.toHaveBeenCalled();
});
it('retains standalone interview tickets without a mission allocation', async () => {
  const response = await POST(request({ engine: 'gemini', corvus: { itemId: 'milk' } }));
  const ticket = await response.json();
  expect(response.status).toBe(200);
  expect(ticket).toMatchObject({ url: 'wss://glasses.test', token: 'signed-test-ticket' });
  expect(ticket.room).toMatch(/^corvus-milk-/);
  expect(mocks.dispatch).toHaveBeenCalledWith(ticket.room, 'corvus-glasses');
  expect(mocks.mission).not.toHaveBeenCalled();
});
