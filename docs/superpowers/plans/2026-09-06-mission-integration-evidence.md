# Mission integration evidence

## Actual token service

The compiled iOS gateway URL points to the Vercel preview for `pulse-iq/pulseiq-client`, branch `hack/corvus-glasses`, under `/api/glasses`. Device settings can override that compiled URL.

Inspected cached source commit: `61670840e6b09b75ea283772d3fb73d2373825bf`.

- Token route: `app/api/glasses/livekit-token/route.ts`.
- Health route: `app/api/glasses/health/route.ts`.
- Authentication: existing shared `CORVUS_GLASSES_TOKEN` bearer credential; this prototype does not have individual shopper accounts.
- LiveKit configuration: `CORVUS_LIVEKIT_URL`, `CORVUS_LIVEKIT_API_KEY`, `CORVUS_LIVEKIT_API_SECRET`, falling back to corresponding `LIVEKIT_*` values.
- Existing route creates a fresh room, forwards the full `corvus` object in room and participant metadata, explicitly dispatches `corvus-glasses`, and returns a 15-minute participant token.
- Existing worker chooses the model from participant metadata and handles Corvus interview logic locally. It does not call the main Corvus interview API.

The `gateway/` directory in the glasses repo is upstream infrastructure and is not the source of this deployed glasses token route. No changes are planned there.

## Companion checkout

Gateway implementation is isolated at `/private/tmp/corvus-mission-gateway` on `codex/glasses-mission-gateway`. It starts from the inspected glasses branch above. The existing web repo's `dev` checkout and its untracked AGENTS.md remain untouched. No push or deployment has been performed.

## Local verification environment

- Xcode 26.6 (17F113).
- LiveKit Swift pin in glasses project: 2.16.0.
- Available simulator: iPhone 17 Pro, iOS 26.5, UUID `1D0DA2EC-E802-4FA5-97CC-C6F01F494080`.
- Existing cached Swift packages are in the CameraAccess DerivedData SourcePackages directory.
- CoreSimulator requires sandbox escalation; read-only device listing succeeded after escalation.

Package compatibility, test results, and remaining live-device checks are recorded in the [validation report](2026-09-06-mission-validation.md). Source inspection is evidence of the checked-in service contract, not proof that the currently deployed preview has a matching build.
