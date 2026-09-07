# Standalone Corvus web backend implementation plan

**Goal:** Own the complete glasses backend in `web/` in this repository and deploy it independently to Vercel.

**Architecture:** Keep iOS under `samples/CameraAccess`, the LiveKit worker under `agent/`, and the authenticated HTTP backend under `web/`. Preserve `/api/glasses/{health,livekit-token,mission-status,mission-end}` and the mission protocol. The web service uses LiveKit, its own Upstash Redis configuration, S3, and Vercel Workflow; it imports no code or configuration from another checkout. The old upstream `gateway/` remains a separate optional service.

**Authorization:** User explicitly requested this repository restructuring and separate Vercel backend. Implement locally on the current test branch; hosting configuration and instructions are included. A live project/domain cutover is separate from source extraction.

## Tasks

- [x] Copy the four route handlers, mission service/watchdog, and their existing tests into `web/`. Preserve tested behavior.
- [x] Add standalone pinned npm dependencies and lockfile, TypeScript/Vitest config, and `withWorkflow` Next config. Use an API-only root response; no unrelated web UI or external fonts.
- [x] Add health and token route boundary tests covering missing configuration, unauthorized requests, mission dispatch contract, and legacy ticket support. Run all web tests and typechecking.
- [x] Build independently with `npm ci` and `npm run build`; verify generated Workflow routes and run a local HTTP smoke test without cloud credentials.
- [x] Add `web/.env.example`, Vercel root-directory setup, and update root README, iOS endpoint template/setup, and current architecture/realtime docs. Remove hardcoded client-preview URLs; use an explicitly configured gateway URL.
- [x] Record verification, commit the extraction on the current branch, and report deployment/cutover steps without claiming a live endpoint exists.

## Verification

- Standalone Node 22.23.2 clean `npm ci` succeeds using only `web/package.json` and `web/package-lock.json`.
- `npm run check`: 22 tests across five files pass; `next typegen` and TypeScript pass.
- `npm run build`: production build succeeds without service secrets; compiled output includes all four API handlers and the Workflow flow/step/webhook handlers, with `missionWatchdog` registered.
- Local `next start` HTTP smoke passes: service root200, health401 without authorization/200 with the test token, token/status/end401 without authorization, Workflow flow GET405 (registered POST route). Server stopped after the test.
- npm audit reports zero vulnerabilities. Compatible overrides patch Workflow's pinned nanoid and undici dependencies; no Workflow major-version change.
- The old preview URL is removed from the committed iOS template and this checkout's generated endpoint setting. Existing installed apps with saved overrides must be pointed at the new service after deployment.
- No Vercel project, domain, cloud credentials, or worker deployment was created. The source is ready for a dedicated Vercel project with Root Directory `web`.
