# android-device-loop

Real-device test loop for my Android apps using **Android CLI device
streaming** (announced 2026-10-05): book a real Pixel from the terminal,
push builds, pull logs/screenshots over secure ADB — no physical phone
needed.

Primary target: **Throw Assistant** (`Bobbywasabi31/overlay-app`) —
build/push/log/screenshot loops without my SM-S908U1 in hand.
Secondary: **OddDough** (`Bobbywasabi31/odddough-android`) physical-device
checklist (roadmap #93).

## Pricing — verified from official docs

- **30 no-cost minutes per project, per month** on the Spark (free) plan.
- After that: **$0.15 per additional minute** (Blaze plan).
- Device setup time (before you connect) and erase time (after you end)
  are **not billed**.
- Sources: [Firebase pricing](https://firebase.google.com/pricing/),
  [Test Lab quotas](https://firebase.google.com/docs/test-lab/usage-quotas-pricing),
  [device streaming docs](https://developer.android.com/studio/run/android-device-streaming).

Practical note: 30 min/month is tight. One smoke loop ≈ 5–10 min, so
budget ~3–6 runs/month on the free tier. Keep sessions short; always
`disconnect` + `remove` when done (billed while reserved).

## Project linking — verified + unknowns

Verified:

- Commands take `--project=` = **a Google Cloud project ID**.
- `android device remote projects` lists the projects ready for streaming.
- Before anything: `android auth login` (sign in with an account that has
  access to a project with device streaming enabled).
- "Remote devices are billed to a Google Cloud project."
- Set a default once in `~/.androidrc` (Windows: `%USERPROFILE%\.androidrc`):
  `device remote --project my-project-id`
- **No billing required for the free tier** — the official device-streaming
  docs say it is "available to you to try at no cost with Firebase projects
  on a Spark plan. Usage beyond the monthly no cost minutes may incur
  billing." Billing (Blaze) only kicks in past the free minutes.
- **The CLI path shares the same quota** — the official device-streaming
  docs page points to `android device remote` as the non-Studio route into
  the same Firebase-powered service ("Try Android CLI if you're not using
  Android Studio"), billed to the same Google Cloud project. So the CLI and
  Studio routes draw from the project's one monthly quota.
- Sources: [device streaming docs](https://developer.android.com/studio/run/android-device-streaming),
  [command reference](https://developer.android.com/tools/agents/android-cli/commands/device_remote),
  [CLI release notes](https://developer.android.com/tools/agents/android-cli/release-notes).

Unknowns (marked, not guessed):

- Default reservation length and exact `create` duration flags
  (`extend --duration <minutes>` exists per release notes).

## Install

1. Download Android CLI: https://developer.android.com/tools/agents
2. `android update` — stay current, this is days old.
3. `android init` — installs the `android-cli` skill for agents.
4. `android auth login`
5. `android device remote projects` — confirm your project shows up.
6. `android device remote models` — pick a `<codename>/<api>`.

Useful skills for later: `android skills list`, then
`android skills add testing-strategy --project=.` (screenshot testing
infra), `android-profiler`, `play-policy-audit`.

## The loop (Throw Assistant)

```
book device → push build → install APK → run journey → pull screenshots + logcat → release device
```

See `scripts/stream-loop.sh` for the commented command sequence and
`journeys/throw-flow.md` for the scripted smoke test.

Typical session:

```bash
android device remote create <codename>/<api> --project=$GCP_PROJECT
# device attaches to adb (or: android device remote connect <reservation-id>)
adb install -r app-debug.apk
# ... run journey steps, capture evidence ...
adb logcat -d > logcat.txt
android screen capture -o shot.png
android device remote disconnect <reservation-id> --project=$GCP_PROJECT
android device remote remove <reservation-id> --project=$GCP_PROJECT
```

## Journeys

Journeys = natural-language user flows the **agent** executes against the
device (official model per
[docs](https://developer.android.com/tools/agents/android-cli/journeys)):
the agent converts each step into interactions using `android screen`
(annotated screenshots), `android layout` (UI tree), and `adb shell input`.
They run from the terminal and in CI. Format is XML — see
`journeys/throw-flow.md`.

## OddDough application

Roadmap #93 (physical-device checklist): stream a Pixel Fold / large-screen
device and run the tablet/landscape/foldable checks from 1.51.0 without
owning the hardware. Same loop, different journey file.

## What it can't do — read this first

- **It will NOT replace gameplay playtests.** Streamed devices are wiped
  lab Pixels/Samsung/etc. Your game won't be installed, won't log in, and
  can't be meaningfully played there. Ring-detection tuning still needs
  your real phone.
- The win is everything *around* detection: does the APK install, does the
  overlay service start, does it survive rotation/backgrounding, what does
  logcat say on a clean device, screenshots for the debug HUD on hardware
  you don't own.
- 30 free min/month means this is a scalpel, not a CI-every-push hammer —
  unless you pay the $0.15/min.

## Open TODOs

- [ ] Confirm `create` output format (how the reservation id is returned)
- [x] Confirm `android screen` subcommand spelling (`capture`? flags?) — verified 2026-10-06: `android screen capture -o shot.png`, `--annotate` flag supported (4 independent android-cli references agree)
- [x] Confirm billing requirement on the GCP project — not required for the
  free tier; Spark (no billing) works, billing (Blaze) only past free minutes
- [ ] Non-interactive auth story for CI (`android auth login` is interactive)
- [x] Verify the 30-min Spark quota applies to CLI streaming — yes, CLI is
  the same Firebase device-streaming service and shares the project quota
