---
name: setup-corvus
description: Set up Corvus from a fresh clone and install it on a connected iPhone — preflight the toolchain, collect the few values that cannot be discovered, then build, install, and verify. Use when someone asks to set up, install, or get Corvus running on a phone.
---

# Setting up Corvus

Take a fresh clone to a working install on the user's phone. Do the mechanical
work unattended, ask once for what you cannot discover, then build and install.

Run every command from the repository root unless a step says otherwise.

## Rules

**Never guess a credential or an identifier.** The Apple team id and the model
key cannot be derived. Propose a value only when a command produced it; ask
otherwise.

**Do not deploy anything.** The realtime worker in `agent/` already runs in the
cloud, and the token endpoint is already deployed. There is no step in this
setup that runs `lk agent deploy`, `fly deploy`, or `vercel`. If realtime does
not work, it is configuration, not a missing deployment.

**Never commit or stage anything.** This setup writes two gitignored files. If
you find yourself about to `git add`, stop.

**Verify, do not assume.** Corvus fails silently by design in several places —
an unbundled study looks exactly like a broken watcher, a wrong microphone
sounds like a bad interview. Every phase below ends in a check with a pass
condition. A phase that "completed" without its check has not completed.

---

## Phase 1 — Preflight (no questions)

Run these and report a single summary. Do not stop at the first failure; collect
them all, since the user can fix them in one pass.

```bash
xcodebuild -version                        # need Xcode 15+
xcrun devicectl list devices               # need one device, state "available (paired)"
ls samples/CameraAccess/CameraAccess/Corvus/Studies/*.json   # need at least one study
```

| Check | Pass condition | If it fails |
|---|---|---|
| Xcode | 15.0 or newer | Ask the user to install or select it with `xcode-select` |
| Device | a row reading `available (paired)` | Ask them to connect and unlock the phone, and trust the Mac |
| Studies | at least one `.json` | Stop — the watcher will run but never fire. See `docs/studies.md` |

Then seed the secrets file if it is absent. Never overwrite an existing one:

```bash
[ -f samples/CameraAccess/CameraAccess/Secrets.swift ] \
  || cp samples/CameraAccess/CameraAccess/Secrets.swift.example \
        samples/CameraAccess/CameraAccess/Secrets.swift
```

**Survey what secrets are already present.** Secrets belong in `.env` at the
repo root -- one file, gitignored, which Phase 3 reads to populate
`Secrets.swift`. Report only which names are *set*, never their values:

```bash
[ -f .env ] && awk -F= '/^[A-Z_]+=/ && $2 != "" {print $1 " set"}' .env || echo "no .env"
```

`GOOGLE_API_KEY` (or `GEMINI_API_KEY`) is required for detection.
`CORVUS_GLASSES_TOKEN` and `CORVUS_GLASSES_URL` are required for realtime missions.
The endpoint is this repository’s `web/` Vercel deployment; see `web/README.md`.
`OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are for detector benchmarking and can
stay empty.

**Check the user is on the expected Apple team.** Team and bundle identifier
are committed in `Signing.xcconfig`, so most people need no signing input at
all. Confirm rather than assume — catching this now is much cheaper than a
signing failure twenty minutes into a build:

```bash
xcodebuild -project samples/CameraAccess/CameraAccess.xcodeproj -target CameraAccess \
  -showBuildSettings 2>/dev/null | grep -E '^\s+DEVELOPMENT_TEAM '

for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$p" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null
done | sort -u
```

If the committed team appears in the second list, signing needs nothing from the
user. If the lists do not overlap, or the second is empty, they are either not
on the team or have never built for iOS on this Mac — flag it for Phase 2 and
carry on with preflight.

Do **not** use `security find-identity` for this. It prints a certificate id
that looks like a team id and is not one.

Also capture both device identifiers now — they are different and each is used
by a different tool:

```bash
xcrun devicectl list devices                                    # Identifier column -> devicectl
xcodebuild -showdestinations -project samples/CameraAccess/CameraAccess.xcodeproj \
  -scheme CameraAccess 2>/dev/null | grep 'platform:iOS,'        # id= -> xcodebuild
```

## Phase 2 — Ask once

**Prefer the file over the conversation.** If a value is missing, ask the user
to put it in `.env` (copying `.env.example` if needed) and tell you when it is
saved -- then re-run the survey command. A secret pasted into chat ends up in
the transcript; one written to a gitignored file does not. Accept a pasted value
only if the user offers it after being given the file option.

Batch the whole ask into one question:

1. **`GOOGLE_API_KEY`** -- required, if the survey did not find it. From
   <https://aistudio.google.com/apikey>.
2. **`CORVUS_GLASSES_TOKEN`** -- required for the default `liveKit`
   interceptor, which is what a fresh install runs. Delivered out of band,
   never committed. If the user does not have one, say so plainly and tell them
   to switch Settings -> Corvus -> Intercepts -> Style to Conversational, which
   needs no server.
3. **`CORVUS_GLASSES_URL`** -- the standalone `web/` deployment URL, including
   `/api/glasses`, without a trailing slash. If it is not deployed yet, follow
   `web/README.md` first. Do not reuse the former main-app preview URL.

Ask about signing **only if the Phase 1 team check did not match**. In that case
the user is building from outside the team and needs both their own team id
(Xcode → Signing & Capabilities shows it) and their own bundle identifier, since
an explicit App ID belongs to exactly one team. Offer to append a suffix — e.g.
`com.meetcorvus.glasses.<initials>` — and explain the consequences: the app
re-registers with the Meta AI app, and the `devicectl` pull path in
`docs/output.md` changes with it.

## Phase 3 — Write, build, install

Write `Signing.local.xcconfig` **only if** Phase 2 established the user is
outside the committed team. On the team, the committed `Signing.xcconfig` is
already correct and this file must not exist — it would silently override the
working values.

```bash
cat > samples/CameraAccess/Signing.local.xcconfig <<EOF
DEVELOPMENT_TEAM = <TEAM_ID>
PRODUCT_BUNDLE_IDENTIFIER = <BUNDLE_ID>
EOF
```

Populate `Secrets.swift` from `.env`. This prints only which placeholders are
still unfilled — never a value, so nothing sensitive reaches the transcript:

```bash
python3 - <<'PY'
import pathlib, re
env = {}
p = pathlib.Path(".env")
if p.exists():
    for line in p.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")

s = pathlib.Path("samples/CameraAccess/CameraAccess/Secrets.swift")
t = s.read_text()
for placeholder, value in (
    ("YOUR_GEMINI_API_KEY",    env.get("GOOGLE_API_KEY") or env.get("GEMINI_API_KEY")),
    ("YOUR_OPENAI_API_KEY",    env.get("OPENAI_API_KEY")),
    ("YOUR_ANTHROPIC_API_KEY", env.get("ANTHROPIC_API_KEY")),
):
    if value:
        t = t.replace(placeholder, value)
if env.get("CORVUS_GLASSES_URL"):
    import json
    t = re.sub(r'(static let cloudGatewayURL\s*=\s*)"[^"\n]*"',
               lambda m: m.group(1) + json.dumps(env["CORVUS_GLASSES_URL"].rstrip('/')), t)
if env.get("CORVUS_GLASSES_TOKEN"):
    t = re.sub(r'(static let cloudGatewayToken = )""',
               lambda m: m.group(1) + '"' + env["CORVUS_GLASSES_TOKEN"] + '"', t)
s.write_text(t)
print("unfilled:", [x for x in ("YOUR_GEMINI_API_KEY", "YOUR_OPENAI_API_KEY",
                                "YOUR_ANTHROPIC_API_KEY") if x in t] or "none")
print("realtime token set:", 'cloudGatewayToken = ""' not in t)
PY
```

`YOUR_GEMINI_API_KEY` must not appear in the unfilled list — the watcher cannot
detect anything without it. The other two are fine to leave. Leave
`cloudGatewayURL` alone; it already points at the deployed endpoint.

Confirm the settings resolve before building:

```bash
cd samples/CameraAccess
xcodebuild -project CameraAccess.xcodeproj -target CameraAccess -showBuildSettings 2>/dev/null \
  | grep -E '^\s+(DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER) '
```

Both must print the expected values. An absent `DEVELOPMENT_TEAM` means the
xcconfig did not take — an empty build setting is omitted from this output
entirely rather than shown as blank.

Build. This takes several minutes on a first run because Swift packages resolve
and a WebRTC xcframework downloads. Run it in the background and wait rather
than polling.

```bash
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -configuration Debug \
  -destination 'id=<XCODEBUILD_DEVICE_ID>' -derivedDataPath <scratch>/dd \
  -allowProvisioningUpdates build
```

Then verify the product before installing it — these are the checks that catch
the silent failures:

```bash
APP=<scratch>/dd/Build/Products/Debug-iphoneos/CameraAccess.app
codesign -dvvv "$APP" 2>&1 | grep -E 'TeamIdentifier|Identifier='   # must match Phase 2

# every study in the source tree must have reached the bundle
for f in ../../samples/CameraAccess/CameraAccess/Corvus/Studies/*.json; do
  b=$(basename "$f")
  [ -f "$APP/$b" ] && echo "bundled: $b" || echo "MISSING FROM BUNDLE: $b"
done
```

A build that succeeds with zero studies in the bundle produces an app that
launches, streams, and never triggers. Do not install it — go back to Phase 1.

Install:

```bash
xcrun devicectl device install app --device <DEVICECTL_IDENTIFIER> "$APP"
```

Pass condition: the output reports `App installed:` with the expected bundleID.

## Phase 4 — On the phone

These need the user's hands, and the order matters. Give them as a numbered list
and wait — do not try to drive this from the shell.

The sequence below is what actually happens on a real device. It involves
**two separate trips to the Meta AI app**, and the second one is delayed, which
is the part that looks broken and is not.

1. **Trust the developer** if iOS asks — Settings → General → VPN & Device
   Management.
2. **Enable Developer Mode in the Meta AI app** — Settings → App Info → tap the
   version number five times, then back out and toggle Developer Mode on. Only
   **one** third-party app can be registered in Developer Mode at a time;
   registering Corvus unregisters whatever was there before.
3. **Open Corvus.** It asks for Bluetooth first, then camera. Allow both. The
   camera prompt is for the *phone* camera; glasses camera is a separate grant
   further down.
4. **Settings (gear icon) → switch Camera from `iPhone Camera` to `Glasses`,
   and save.** Nothing about the glasses appears until this is set.
5. **Tap the blue "Connect my glasses" button.** This hands off to the Meta AI
   app, which asks you to connect an **unverified app** — that wording is
   expected in Developer Mode, where attestation is skipped, not a sign anything
   is wrong. Approve it.
6. **Back in Corvus, wait a few seconds.** It will bounce you to the Meta AI app
   a *second* time, now asking to allow **camera access on Meta devices**. This
   delay is normal — registration and permission are two separate round trips in
   the DAT integration lifecycle. Do not tap anything in Corvus while waiting.
   Approve the camera grant.
7. **Wait for the feed, and allow the microphone when asked.** On a fresh
   install the first frame takes roughly half a minute to arrive — that is DAT
   coming up, not a fault. Measured from the session log: ~31-36s on a fresh
   install, ~13s when the camera grant was already in place. Nothing needs
   tapping while you wait.

Then confirm it works: pick up something on the watchlist and check that the
watcher fires. `grocery-pilot` watches for olive oil, yogurt and six others —
read the study file for the list.

## When something does not work

Corvus's characteristic failure is silence, so map symptoms to causes rather
than waiting for an error.

| Symptom | Likely cause |
|---|---|
| Watcher runs, never fires | No studies bundled, or a study failed to decode — Settings surfaces decode errors with reasons |
| Watcher runs, never fires, studies present | `streakWindow` too short for the detector's latency; see `docs/architecture.md#tuning` |
| Signing error at build | `Signing.local.xcconfig` missing or wrong; bundle id belongs to another team |
| App installs, glasses never connect | Developer Mode off, or another app holds the single registration slot |
| Screen dark but `events.jsonl` still logging `detection` rows | Frames are arriving and only the display is broken — the two ride different paths (`onAnalysisFrame` feeds the watcher, `onDecodedFrame` feeds the screen). Look at the preview track and whether `glassesCapturerBox` got wired, not at the stream |
| Stuck after approving the unverified app | The second Meta AI hand-off is delayed by a few seconds; wait rather than tapping |
| Realtime says no worker joined | Wrong or missing `cloudGatewayToken` — Settings' gateway status line distinguishes a bad token from an unreachable server |
| Realtime works, bucket empty | Interceptor style is still `conversational`; only realtime records |
| Interview audio came from the wrong mic | Another Bluetooth device won the route; `GlassesAudioSession` matches by name |

Deeper background is in `docs/`. Do not deploy anything to fix any of these.
