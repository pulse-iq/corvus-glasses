# Corvus

**Intercept interviews through Meta Ray-Ban glasses.** Someone wearing the
glasses picks up a product the study is watching for; the app notices and asks
them about it, out loud, in the moment.

The point is research data captured at the moment of choice rather than recalled
afterwards in a room. A shopper can tell you why they bought oat milk a week
later; what they can't tell you is what they were looking at on the label three
seconds before they put it in the basket.

```
glasses ──> phone samples ~1fps ──> vision model ──> "they just picked up the olive oil"
                                                              │
                                          "What made you reach for that one?"
                                                              │
                                              spoken, answered, transcribed, filed
```

Two halves: a **watcher** that decides whether a moment is worth interrupting,
and an **intercept** that conducts the conversation. See
[docs/architecture.md](docs/architecture.md).

## Status

A research prototype, iOS only. The Android sample in this repo is upstream's
and carries no Corvus code.

It runs on a phone paired with Meta Ray-Ban glasses in Developer Mode. There is
no App Store build. This repository contains the iOS app, the LiveKit worker,
and a standalone Vercel backend. Missions save local records and cloud recordings.

## Repository structure

| Directory | Responsibility | Deployment |
|---|---|---|
| `samples/CameraAccess/` | iOS app, camera, detection, mission controls | Xcode/device |
| `agent/` | Welcome, product interviews, mission recording | LiveKit Cloud |
| `web/` | Room tokens, mission lifecycle/status, cleanup watchdog | Vercel, Root Directory `web` |
| `gateway/` | Retained upstream action gateway | Optional; not the mission backend |

The web service has its own npm lockfile and environment. It does not depend on
another repository. See [web/README.md](web/README.md) for local setup and Vercel
configuration. Deploying `web/` does not deploy the Python worker.

## Setup

If you use Claude Code, run:

```
/setup-corvus
```

It checks your toolchain, finds your phone, asks once for the handful of things
it cannot discover — a model key, your Apple team — then builds, installs, and
verifies the install. The same file is readable as a plain runbook:
[`.claude/skills/setup-corvus/SKILL.md`](.claude/skills/setup-corvus/SKILL.md).

By hand, the short version:

```bash
cd samples/CameraAccess
cp CameraAccess/Secrets.swift.example CameraAccess/Secrets.swift
# fill in Gemini API key, web service URL, and shared token in Secrets.swift
open CameraAccess.xcodeproj                      # signing is already configured
```

Then enable Developer Mode in the Meta AI app — Settings → App Info → tap the
version five times — and register Corvus when the app asks.

![How to enable Developer Mode](assets/dev_mode.png)

**Signing.** Team and bundle identifier are committed in
`samples/CameraAccess/Signing.xcconfig` and need no edit if you are on the Snag
Ventures Apple Developer team — a Team ID belongs to a membership rather than a
person, and the App ID is registered to the team. Your phone registers itself to
the team on the first build.

Building from outside that team means overriding both, bundle identifier
included, in a gitignored `Signing.local.xcconfig` beside it. Changing the bundle
identifier also means re-registering with the Meta AI app, and it changes the
`--domain-identifier` in the pull command in [docs/output.md](docs/output.md).

**Requirements.** iOS 17+, Xcode 15+, a Gemini API key, Meta Ray-Ban glasses,
and membership of the Apple Developer team the project is signed for. The
realtime interceptor additionally needs a token endpoint and its token —
everything else runs with no server at all.

## Docs

| | |
|---|---|
| [architecture.md](docs/architecture.md) | How a pickup becomes an intercept |
| [studies.md](docs/studies.md) | Configuring what it watches for and what it asks |
| [output.md](docs/output.md) | What a session produces, and how to get it off the phone |
| [realtime.md](docs/realtime.md) | The low-latency voice interceptor |

## Built on VisionClaw

Corvus is a fork of [VisionClaw](https://github.com/Intent-Lab/VisionClaw), which
provides the glasses streaming, the LiveKit session, and the app shell it is
built inside. Corvus owns its own files under `CameraAccess/Corvus/` and touches
upstream ones only at small seams, which is what keeps pulling from upstream
survivable.

If you use VisionClaw in your research, please cite their paper:

```bibtex
@article{liu2026visionclaw,
  title={VisionClaw: Always-On AI Agents through Smart Glasses},
  author={Liu, Xiaoan and Lee, DaeHo and Gonzalez, Eric J and Gonzalez-Franco, Mar and Suzuki, Ryo},
  journal={arXiv preprint arXiv:2604.03486},
  year={2026}
}
```

Built on the [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios).

## License

This source code is licensed under the license found in the [LICENSE](LICENSE)
file in the root directory of this source tree. Third-party notices are in
[NOTICE](NOTICE).
