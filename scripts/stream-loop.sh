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
# For CI you need a non-interactive story — TODO: check docs for service-account flow.
# android auth login

# 1. Reserve a real device. Billed while reserved — keep it short.
log "reserving ${MODEL} ..."
# TODO: confirm how create returns the reservation id (stdout? --format=json?)
CREATE_OUT="$(android device remote create "${MODEL}" ${PROJECT_FLAG})"
echo "$CREATE_OUT" | tee "${ARTIFACTS}/reservation.txt"
# TODO: parse the real reservation id; placeholder below
RES_ID="$(echo "$CREATE_OUT" | grep -oE '[a-zA-Z0-9-]+' | head -1)"
log "reservation id: ${RES_ID} (TODO: verify parsing)"

# 2. Attach to adb (create usually auto-connects; use --connect=false + explicit connect if not)
# TODO: confirm flag name for skipping auto-connect
# android device remote connect "${RES_ID}" ${PROJECT_FLAG}
adb wait-for-device
log "device online: $(adb shell getprop ro.product.model)"

# 3. Push + install the build
adb install -r "$APK"
log "installed $APK"

# 4. Launch the app
# TODO: confirm Throw Assistant's real package / launcher activity
PKG="com.example.throwassistant"   # TODO: replace with real applicationId
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
sleep 3

# 5. Evidence: screenshot + UI tree + logcat
# `android screen capture` (verified via android-cli SKILL.md references, 2026-10-06)
android screen capture --annotate -o "${ARTIFACTS}/launch.png" || \
  adb exec-out screencap -p > "${ARTIFACTS}/launch.png"
android layout --pretty > "${ARTIFACTS}/layout.txt" 2>/dev/null || true
adb logcat -d > "${ARTIFACTS}/logcat.txt"
log "evidence in ${ARTIFACTS}/"

# 6. Journey steps (agent-driven; see journeys/throw-flow.md).
# The agent executes each natural-language step using android screen/layout + adb input.
# TODO: confirm journeys invocation for the installed CLI version (`android help`).

# 7. ALWAYS release the device — billed while reserved.
log "releasing device ..."
android device remote disconnect "${RES_ID}" ${PROJECT_FLAG} || true
android device remote remove "${RES_ID}" ${PROJECT_FLAG} || true
log "done. artifacts: ${ARTIFACTS}/"
