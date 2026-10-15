#!/usr/bin/env bash
#
# stream-loop.sh — example real-device smoke loop for Throw Assistant
# via Android CLI device streaming.
#
# DRAFT. Command names come from the official docs; anything uncertain is
# marked TODO. Do not run blind — verify each TODO with `android <cmd> -h`.
#
# Env:
#   GCP_PROJECT   Google Cloud project id with device streaming enabled (required)
#   APK           path to the debug APK to test (required)
#   MODEL         device as <codename>/<api>, e.g. from `android device remote models`
#                 (required — pick a real one, don't guess)
#
# Usage:
#   GCP_PROJECT=my-proj APK=app-debug.apk MODEL=panther/34 bash scripts/stream-loop.sh
#   bash scripts/stream-loop.sh --dry-run   # no device / no GCP project:
#                                           # full loop against mock android+adb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --dry-run: shadow android+adb with the mocks in scripts/dry-run/ (they record
# every call and return canned outputs) and relax the env requirements, so the
# whole reserve -> push -> install -> capture -> release path validates with
# no device, no GCP project, and no cost.
DRY_RUN=0
# Billing guard: streaming minutes burn while a device is reserved (the free
# tier is 30 min/project/month, then $0.15/min), so the device-facing steps
# below are capped via coreutils `timeout` (or Homebrew `gtimeout` on macOS),
# resolved pre-flight so a machine that can't enforce the guard never reserves
# (and bills) a device. Fractions of a minute are allowed;
# 0 disables the guard.
MAX_MINUTES=25
usage() {
  cat <<'EOF'
stream-loop.sh — example real-device smoke loop for Throw Assistant
via Android CLI device streaming.

Usage:
  GCP_PROJECT=my-proj APK=app-debug.apk MODEL=panther/34 bash scripts/stream-loop.sh
  bash scripts/stream-loop.sh --dry-run     # full loop against mock android+adb:
                                            # no device, no GCP project, no cost
  bash scripts/stream-loop.sh --help        # this text

Env (required unless --dry-run):
  GCP_PROJECT   Google Cloud project id with device streaming enabled
  APK           path to the debug APK to test
  MODEL         device as <codename>/<api>, e.g. panther/34 — pick a real one
                from `android device remote models`, don't guess

Flags:
  --dry-run       run the whole loop against the mocks in scripts/dry-run/
  --max-minutes=N cap the device-facing steps (2-5) at N minutes (default 25;
                  fractions allowed, 0 disables). On expiry the steps are
                  terminated, the reservation is still released, exit 124.
                  Needs coreutils 'timeout' on PATH ('gtimeout' works too,
                  e.g. via 'brew install coreutils' on macOS); the script
                  checks this before reserving any device.
  --help, -h      print this help and exit 0

Steps:
  1. reserve a real device (billed while reserved — keep it short)
  2. wait for adb, 3. install the APK, 4. launch the app,
  5. capture evidence (screenshot, UI layout, logcat) into artifacts/<ts>/
  6. journey steps are agent-driven (see journeys/throw-flow.md)
  7. the reservation is ALWAYS released via an EXIT trap, even on failure;
     --max-minutes also caps steps 2-5 so a hung adb can't burn the whole
     streaming-minutes quota (exit 124 on expiry)

  Each numbered step is timed into artifacts/<ts>/steps.log (tab-separated:
  step, label, UTC start, duration seconds) so a billed run can be audited
  for where the streaming minutes went; step durations also print in the
  console log ("step N: <label> done in Ns").
EOF
}
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --max-minutes) echo "stream-loop.sh: error: --max-minutes needs a value: --max-minutes=N (minutes, 0 disables)" >&2; exit 2 ;;
    --max-minutes=*) MAX_MINUTES="${arg#--max-minutes=}" ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "stream-loop.sh: error: unknown flag '$arg' (try --help)" >&2; exit 2 ;;
    *)  echo "stream-loop.sh: error: unexpected argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done
if [[ ! "$MAX_MINUTES" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "stream-loop.sh: error: --max-minutes must be a non-negative number of minutes (0 disables), got '$MAX_MINUTES'" >&2
  exit 2
fi
# Whole seconds, rounded up so a fractional request can never become a 0s timeout.
TIMEOUT_SECS="$(awk -v m="$MAX_MINUTES" 'BEGIN { s = m * 60; printf "%d", (s > int(s) ? int(s) + 1 : int(s)) }')"

# Resolve the guard binary once, up front: plain `timeout` on Linux, or
# Homebrew coreutils' `gtimeout` on macOS (GNU tools install g-prefixed by
# default unless gnubin is on PATH). Pre-flight on purpose — it runs BEFORE
# the device reservation below, so a machine that can't enforce the billing
# guard never reserves (and bills) a device it can't cap.
resolve_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then echo timeout; return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then echo gtimeout; return 0; fi
  return 1
}
TIMEOUT_BIN=""
if (( TIMEOUT_SECS > 0 )); then
  TIMEOUT_BIN="$(resolve_timeout_bin)" || {
    echo "stream-loop.sh: error: --max-minutes needs coreutils 'timeout' on PATH" >&2
    echo "stream-loop.sh: hint: macOS: 'brew install coreutils' exposes it as 'gtimeout'; or pass --max-minutes=0 to run uncapped" >&2
    exit 2
  }
fi

if (( DRY_RUN )); then
  : "${GCP_PROJECT:=dry-run-project}"
  : "${APK:=dry-run-fixture.apk}"
  : "${MODEL:=panther/34}"
  export PATH="$SCRIPT_DIR/dry-run:$PATH"
else
  : "${GCP_PROJECT:?set GCP_PROJECT}"
  : "${APK:?set APK path}"
  : "${MODEL:?set MODEL as <codename>/<api> from 'android device remote models'}"
fi

PROJECT_FLAG="--project=${GCP_PROJECT}"
ARTIFACTS="artifacts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ARTIFACTS"
printf '# step\tlabel\tstart_utc\tduration_s\n' > "${ARTIFACTS}/steps.log"

if (( DRY_RUN )); then
  export ANDROID_MOCK_STATE="$ARTIFACTS/mock-state"
  export ANDROID_MOCK_CALLS="$ARTIFACTS/android-calls.log"
  mkdir -p "$ANDROID_MOCK_STATE"
  : > "$ANDROID_MOCK_CALLS"
fi

log() { echo "[stream-loop] $*"; }

# --- per-step timing ---------------------------------------------------------
# Each numbered step is timed into ${ARTIFACTS}/steps.log (tab-separated:
# num, label, UTC start, duration seconds) so a billed run can be audited for
# where the streaming minutes went. This complements the --max-minutes guard:
# when the guard fires, the log shows which step ate the time. A step that
# dies under `set -e` simply has no closing row — its start line stays in the
# console output, which is where it died.
step_start() { # step_start <num> <label>
  STEP_NUM="$1"; STEP_LABEL="$2"
  STEP_T0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  STEP_EPOCH="$(date +%s)"
  log "step ${STEP_NUM}: ${STEP_LABEL} ..."
}
step_end() { # step_end — closes the most recent step_start
  if [ -z "${STEP_NUM:-}" ]; then
    echo "[stream-loop] error: step_end with no step open (step_start/step_end mismatch)" >&2
    return 1
  fi
  local dur; dur=$(( $(date +%s) - STEP_EPOCH ))
  log "step ${STEP_NUM}: ${STEP_LABEL} done in ${dur}s"
  printf '%s\t%s\t%s\t%s\n' "$STEP_NUM" "$STEP_LABEL" "$STEP_T0" "$dur" >> "${ARTIFACTS}/steps.log"
  STEP_NUM=""; STEP_LABEL=""; STEP_T0=""; STEP_EPOCH=""
  return 0
}

if (( DRY_RUN )); then
  log "DRY RUN — mocking android/adb from scripts/dry-run/: no device, no GCP project, no cost."
fi

# 0. Auth (one-time per machine; interactive)
# CLI 1.0.16500706 verified 2026-10-07: `android auth login` has no
# non-interactive/service-account/token flag (only --no-use-keyring),
# so CI auth is still an open TODO for Alex's GCP project (see workflow draft).
# android auth login

# 1. Reserve a real device. Billed while reserved — keep it short.
# Verified 2026-10-07 against CLI 1.0.16500706 + official docs (kb://device_remote_create):
# - create prints the reservation id and its end time (exact line format not
#   documented, so resolve the id via list --short diff, with a regex fallback).
# - auto-connect to adb is the DEFAULT (--connect=true); --connect=false
#   reserves only (then run `android device remote connect <id> --project=...`).
step_start 1 "reserve device (${MODEL}, auto-connects to adb)"
BEFORE_IDS="$(android device remote list --short ${PROJECT_FLAG} 2>/dev/null || true)"
CREATE_OUT="$(android device remote create "${MODEL}" --connect ${PROJECT_FLAG})"
echo "$CREATE_OUT" | tee "${ARTIFACTS}/create-output.txt"
AFTER_IDS="$(android device remote list --short ${PROJECT_FLAG} 2>/dev/null || true)"
RES_ID="$(comm -23 <(printf '%s\n' "$AFTER_IDS" | sort) <(printf '%s\n' "$BEFORE_IDS" | sort) | head -1)"
if [ -z "$RES_ID" ]; then
  # fallback: fish an id-looking token out of create's output
  RES_ID="$(echo "$CREATE_OUT" | grep -oiE '[a-z0-9][a-z0-9_-]{5,}' | head -1 || true)"
fi
: "${RES_ID:?could not resolve reservation id; see ${ARTIFACTS}/create-output.txt}"
log "reservation id: ${RES_ID}"
step_end

# ALWAYS release the reservation, even if the loop dies midway: a failed
# install (or any later step) under `set -e` would otherwise leave the device
# reserved and burning the billed/free streaming minutes. Registered here —
# only once RES_ID is actually known — and idempotent via `|| true`.
release_device() {
  if [[ -n "${RES_ID:-}" ]]; then
    log "releasing reservation ${RES_ID} ..."
    android device remote disconnect "${RES_ID}" ${PROJECT_FLAG} || true
    android device remote remove "${RES_ID}" ${PROJECT_FLAG} || true
    log "reservation ${RES_ID} released."
  fi
}
trap release_device EXIT

# 2-5. Device-facing steps. Run in the main shell normally, or under the
# billing guard below (exported as a function for that).
device_steps() {
  # 2. Wait for adb (create auto-connects the device; this just blocks until ready).
  step_start 2 "wait for adb"
  adb wait-for-device
  log "device online: $(adb shell getprop ro.product.model)"
  step_end

  # 3. Push + install the build
  step_start 3 "install APK"
  adb install -r "$APK"
  log "installed $APK"
  step_end

  # 4. Launch the app
  # Launcher: .MainActivity (exported LAUNCHER; .DemoActivity is not exported)
  # applicationId verified from overlay-app/app/build.gradle (2026-10-07)
  step_start 4 "launch app"
  local pkg="com.bobbywasabi.overlayapp"
  adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1
  sleep 3
  step_end

  step_start 5 "capture evidence"
  # 5. Evidence: screenshot + UI tree + logcat
  # Verified 2026-10-07 against CLI 1.0.16500706: `capture` takes
  # `--annotate` and `--output=` (there is NO -o short flag — old scripts that
  # used -o silently fell through to the adb fallback below).
  android screen capture --annotate --output="${ARTIFACTS}/launch.png" || \
    adb exec-out screencap -p > "${ARTIFACTS}/launch.png"
  android layout --pretty --output="${ARTIFACTS}/layout.txt" 2>/dev/null || true
  adb logcat -d > "${ARTIFACTS}/logcat.txt"
  log "evidence in ${ARTIFACTS}/"
  step_end
}

# Billing guard: streaming minutes burn while the device is reserved, so the
# device-facing steps are capped with the pre-flight-resolved $TIMEOUT_BIN
# (default TERM signal). $TIMEOUT_BIN signals only its direct child (the
# bash -c below, which sets no traps and always dies on TERM); the parent
# shell is never signaled, so its EXIT trap still releases the reservation on
# every path. (A TERM trap in this shell would NOT work — bash defers trapped
# signals while a foreground child like a hung `adb` runs, verified
# 2026-10-13.) Exit code is the guard's 124 on expiry.
if (( TIMEOUT_SECS > 0 )); then
  log "billing guard: capping device steps at ${MAX_MINUTES} min (${TIMEOUT_SECS}s) via ${TIMEOUT_BIN}"
  export ARTIFACTS PROJECT_FLAG APK
  export -f device_steps log step_start step_end
  if "$TIMEOUT_BIN" "$TIMEOUT_SECS" bash -c 'set -euo pipefail; device_steps'; then
    log "device steps finished inside the billing guard"
  else
    code=$?
    if (( code == 124 )); then
      log "billing guard fired after ${MAX_MINUTES} min — steps killed, releasing reservation"
    fi
    exit "$code"
  fi
else
  log "billing guard disabled (--max-minutes=0)"
  device_steps
fi

# 6. Journey steps (agent-driven; see journeys/throw-flow.md).
# Verified 2026-10-07: CLI 1.0.16500706 has NO `journey` subcommand, so the
# agent drives each step itself: `android screen capture --annotate
# --output=...` then `android screen resolve --screenshot=<that png>
# --string="tap #3"` to substitute #N labels into adb shell input commands.
# `android layout --pretty` gives the UI tree when a step needs exact ids.

# 7. Release is handled by the release_device EXIT trap (registered right
# after the reservation id resolved) — it runs on success AND on any mid-loop
# failure, so the device is never left reserved and burning streaming minutes.
log "done. artifacts: ${ARTIFACTS}/"
