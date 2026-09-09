# Corvus glasses web service

This is the standalone backend for the iOS app and LiveKit mission worker in
this repository. It deploys as its own Vercel project. It has no imports, runtime
calls, authentication middleware, or build dependencies from `pulseiq-client`.

## Repository boundaries

- `../samples/CameraAccess/`: iOS capture, product detection, mission controls.
- `../agent/`: LiveKit worker, voice interviews, recording coordination.
- `./`: authenticated HTTP routes, room tickets, mission registry, results, and
  a durable cleanup watchdog.

The phone and worker send media directly through LiveKit. This service does not
proxy audio/video or conduct interviews, and it never touches the recording
bucket: LiveKit Egress and the worker write there, nothing here reads. Redis
retains allocation claims and terminal mission IDs; everything else the service
reports comes from LiveKit (worker presence, egress state).

## Local development

Use Node.js 22 or newer and npm. From this directory:

```sh
npm ci
cp .env.example .env.local
# Fill in your dedicated service configuration.
npm run dev
```

`GET /` identifies the service without credentials. All `/api/glasses/*` routes
require `Authorization: Bearer <CORVUS_GLASSES_TOKEN>`. `GET /api/glasses/health`
checks the shared token; it is not a LiveKit/Redis connectivity test.
Local Workflow state is kept in `.workflow-data/`; production uses Vercel's
managed Workflow backend automatically.

```sh
npm run check
npm run build
npm start
```

The lockfile includes compatible security patches for Workflow’s pinned
`nanoid` and `undici` dependencies. Keep the scoped overrides until the Workflow
SDK adopts patched versions. Tests mock external services and need no real
credentials. The production build
also needs no secrets and does not fetch fonts or call external APIs.

## Deploy on Vercel

1. Create a **new Vercel project** importing `pulse-iq/corvus-glasses`.
2. Set **Root Directory** to **`web`**, framework to **Next.js**, and Node.js to
   **22.x**. Use the default install/build commands (`npm ci`, `npm run build`).
   Select the branch containing `web/`; the prototype is currently on
   `codex/mission-session-prototype`.
3. Add every required variable from `.env.example` to the environments you will
   test/deploy. Provision a dedicated Upstash Redis database. Use the same
   glasses LiveKit project as `agent/.env`. No AWS credentials are needed
   here; the worker holds write-only recording credentials.
4. Deploy. `next.config.ts` enables the Workflow compiler; `vercel.json` selects
   `iad1`. The generated `/.well-known/workflow/v1/*` handlers must remain
   accessible to the Workflow runtime. No main-app login middleware is needed.
5. Assign a stable Vercel production alias or your own custom domain. For native
   iOS access, the endpoint cannot require a Vercel browser-login cookie. Use a
   suitable deployment-protection setting for this API; the routes still enforce
   the shared bearer token.
6. Configure the iOS app's **Gateway URL** as
   `https://<your-service-domain>/api/glasses`, without a trailing slash, and use
   the matching shared token. For a new build, set `CORVUS_GLASSES_URL` in the
   repository-root `.env` and run `/setup-corvus`, or fill in
   `Secrets.cloudGatewayURL`. A saved Settings override wins over compiled values.
7. Deploy the Python worker independently using `../agent/setup_livekit_toml.sh`
   and `lk agent deploy --secrets-file .env` from `agent/`. Vercel deploys only
   this HTTP service; it does not deploy the worker or install the iOS app.

No live URL or domain is hardcoded in the source. Creating a project/domain and
configuring its secrets is required before the phone can use this service.

## API contract

| Route | Purpose |
|---|---|
| `GET /api/glasses/health` | Authenticated service identification |
| `POST /api/glasses/livekit-token` | Mission allocation/rejoin or legacy standalone ticket |
| `POST /api/glasses/mission-end` | Durable end request and recorder cleanup |
| `GET /api/glasses/mission-status?missionId=...` | Mission/results and recording status |
| Same status route with `&interceptId=...` | Full durable interview result |

Mission tickets accept `engine` and a `corvus` object containing `mode: "mission"`,
`version: 1`, UUID `missionId`/`segmentId`, `sessionId`, and `studyId`. They return
`url`, `room`, `token`, `missionVersion`, `missionId`, `segmentId`, `phoneIdentity`,
and `workerIdentity`. The named worker is `corvus-glasses`.

One durable allocation claim prevents duplicate room/worker creation. An end
request writes a tombstone even before allocation completes. The independent
Workflow watchdog is scheduled before room creation; it bounds startup at 45
seconds and ends a mission whose worker has left the room. There is no mission
time limit: a trip lasts as long as it lasts, and the worker ends the mission
itself when the phone stops heartbeating. The watchdog requests recording
shutdown even when the phone and worker are gone, then waits up to 30 minutes
for a saved/failed verdict. Saved/finalizing/failed recording status remains
distinguishable. Never expire terminal IDs as a
routine cache cleanup: that could permit a completed mission ID to be reused.

This prototype uses one shared secret, not individual shopper accounts. The
same room can be rejoined; a lost worker ends the mission rather than allocating
an automatic replacement. Start a new mission with a new ID after terminal failure.
