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

set -euo pipefail

: "${GCP_PROJECT:?set GCP_PROJECT}"
: "${APK:?set APK path}"
: "${MODEL:?set MODEL as <codename>/<api> from 'android device remote models'}"

PROJECT_FLAG="--project=${GCP_PROJECT}"
ARTIFACTS="artifacts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ARTIFACTS"

log() { echo "[stream-loop] $*"; }

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
log "reserving ${MODEL} (auto-connects to adb on success) ..."
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

# 2. Wait for adb (create auto-connects the device; this just blocks until ready).
adb wait-for-device
log "device online: $(adb shell getprop ro.product.model)"

# 3. Push + install the build
adb install -r "$APK"
log "installed $APK"

# 4. Launch the app
# Launcher: .MainActivity (exported LAUNCHER; .DemoActivity is not exported)
# applicationId verified from overlay-app/app/build.gradle (2026-10-07)
PKG="com.bobbywasabi.overlayapp"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
sleep 3

# 5. Evidence: screenshot + UI tree + logcat
# Verified 2026-10-07 against CLI 1.0.16500706: `capture` takes
# `--annotate` and `--output=` (there is NO -o short flag — old scripts that
# used -o silently fell through to the adb fallback below).
android screen capture --annotate --output="${ARTIFACTS}/launch.png" || \
  adb exec-out screencap -p > "${ARTIFACTS}/launch.png"
android layout --pretty --output="${ARTIFACTS}/layout.txt" 2>/dev/null || true
adb logcat -d > "${ARTIFACTS}/logcat.txt"
log "evidence in ${ARTIFACTS}/"

# 6. Journey steps (agent-driven; see journeys/throw-flow.md).
# Verified 2026-10-07: CLI 1.0.16500706 has NO `journey` subcommand, so the
# agent drives each step itself: `android screen capture --annotate
# --output=...` then `android screen resolve --screenshot=<that png>
# --string="tap #3"` to substitute #N labels into adb shell input commands.
# `android layout --pretty` gives the UI tree when a step needs exact ids.

# 7. ALWAYS release the device — billed while reserved.
log "releasing device ..."
android device remote disconnect "${RES_ID}" ${PROJECT_FLAG} || true
android device remote remove "${RES_ID}" ${PROJECT_FLAG} || true
log "done. artifacts: ${ARTIFACTS}/"
