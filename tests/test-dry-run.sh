#!/usr/bin/env bash
#
# tests/test-dry-run.sh — validates stream-loop.sh --dry-run end to end.
#
# 1. Runs the full reserve -> push -> install -> capture -> release path
#    against the mock android/adb (no device, no GCP project).
# 2. Asserts the CLI was invoked with the verified spellings — notably
#    `screen capture --output=` (not -o). If the capture spelling ever
#    regresses to -o (task-7 bug), the mock fails, the script falls back to
#    `adb exec-out screencap`, and the "no fallback" assertion below fails.
# 3. Asserts the reservation was actually released (mock state empty).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# --- part 1: mock unit checks -------------------------------------------
ANDROID_MOCK_STATE="$(mktemp -d)"
ANDROID_MOCK_CALLS="$(mktemp)"
export ANDROID_MOCK_STATE ANDROID_MOCK_CALLS

./scripts/dry-run/android screen capture -o /tmp/should-fail.png 2>/dev/null \
  && fail "mock accepted '-o' — must reject like the real CLI"
pass "mock rejects -o for screen capture"

./scripts/dry-run/android screen capture --output=/tmp/mock-cap.png >/dev/null \
  || fail "mock rejected verified --output= spelling"
[ -s /tmp/mock-cap.png ] || fail "mock did not write the PNG"
pass "mock accepts --output= and writes a PNG"

./scripts/dry-run/android boguscmd 2>/dev/null \
  && fail "mock accepted an unknown subcommand"
pass "mock rejects unknown subcommands"

./scripts/dry-run/adb install -r fixture.apk >/dev/null \
  || fail "mock adb install failed"
pass "mock adb install works"

# --- part 2: full loop ----------------------------------------------------
rm -rf artifacts
bash scripts/stream-loop.sh --dry-run > /tmp/dry-run-stdout.txt 2>&1 \
  || { cat /tmp/dry-run-stdout.txt >&2; fail "stream-loop.sh --dry-run exited nonzero"; }
pass "full loop exited 0"

LATEST="$(ls -dt artifacts/*/ 2>/dev/null | head -1)"
[ -n "$LATEST" ] || fail "no artifacts dir created"
CALLS="$LATEST/android-calls.log"
[ -f "$CALLS" ] || fail "android-calls.log missing"

for f in launch.png layout.txt logcat.txt create-output.txt android-calls.log; do
  [ -s "$LATEST/$f" ] || fail "artifact $f missing or empty"
done
pass "all evidence artifacts present"

grep -q '^android device remote create panther/34' "$CALLS" \
  || fail "create not called with model"
grep -q '^android device remote list' "$CALLS" \
  || fail "list not called (id resolution path)"
grep -q 'adb wait-for-device' "$CALLS" \
  || fail "adb wait-for-device not called"
grep -q 'adb install -r dry-run-fixture.apk' "$CALLS" \
  || fail "adb install not called with APK"
grep -q 'adb shell monkey' "$CALLS" \
  || fail "app launch (monkey) not called"
grep -q '^android screen capture --annotate --output=.*launch.png$' "$CALLS" \
  || fail "capture not called with verified --output= spelling"
grep -q 'adb exec-out screencap' "$CALLS" \
  && fail "adb screencap fallback ran — capture spelling regressed (see task 7)"
grep -q '^android device remote disconnect dryrun-reservation-1' "$CALLS" \
  || fail "disconnect not called with reservation id"
grep -q '^android device remote remove dryrun-reservation-1' "$CALLS" \
  || fail "remove not called with reservation id"
pass "call sequence matches the real loop (verified spellings)"

grep -q 'dryrun-reservation-1' "$LATEST/create-output.txt" \
  || fail "create-output.txt missing the reservation id"
RES="$LATEST/mock-state/reservations.txt"
[ -f "$RES" ] || fail "mock state missing"
[ -s "$RES" ] && fail "reservation was NOT released: $(cat "$RES")"
pass "reservation released (mock state empty)"

# --- part 3: mid-loop failure still releases the reservation ---------------
# A failed install (or any step) under set -e must not leave the device
# reserved and burning streaming minutes — the EXIT trap must run
# disconnect + remove on the failure path.
rm -rf artifacts
export ANDROID_MOCK_FAIL_AT="install -r"
if bash scripts/stream-loop.sh --dry-run > /tmp/dry-run-fail-stdout.txt 2>&1; then
  unset ANDROID_MOCK_FAIL_AT
  cat /tmp/dry-run-fail-stdout.txt >&2
  fail "stream-loop.sh --dry-run exited 0 with a failing install"
fi
unset ANDROID_MOCK_FAIL_AT
pass "loop exits nonzero when install fails"

LATEST="$(ls -dt artifacts/*/ 2>/dev/null | head -1)"
[ -n "$LATEST" ] || fail "no artifacts dir created on the failure path"
[ -f "$LATEST/android-calls.log" ] || fail "android-calls.log missing on the failure path"
grep -q '^android device remote disconnect dryrun-reservation-1' "$LATEST/android-calls.log" \
  || fail "EXIT trap did not run disconnect on the failure path"
grep -q '^android device remote remove dryrun-reservation-1' "$LATEST/android-calls.log" \
  || fail "EXIT trap did not run remove on the failure path"
pass "EXIT trap ran disconnect + remove on the failure path"

RES="$LATEST/mock-state/reservations.txt"
[ -f "$RES" ] || fail "mock state missing on the failure path"
[ -s "$RES" ] && fail "reservation NOT released after mid-loop failure: $(cat "$RES")"
pass "reservation released after mid-loop failure (mock state empty)"

# --- part 4: --help + unknown flags ---------------------------------------
# A bare `stream-loop.sh` (no env) dies on the GCP_PROJECT guard with no
# guidance; --help must document usage before any requirement is enforced,
# and typos/mistakes must fail loudly instead of silently running the loop.
bash scripts/stream-loop.sh --help > /tmp/dry-run-help.txt 2>&1 \
  || fail "stream-loop.sh --help exited nonzero"
for want in GCP_PROJECT APK MODEL --dry-run '1. reserve'; do
  grep -q -- "$want" /tmp/dry-run-help.txt \
    || fail "--help output missing '$want'"
done
pass "--help exits 0 and documents env, flags, and steps"

bash scripts/stream-loop.sh -h > /tmp/dry-run-h.txt 2>&1 \
  || fail "stream-loop.sh -h exited nonzero"
pass "-h is an alias for --help"

bash scripts/stream-loop.sh --bogus > /tmp/dry-run-bogus.txt 2>&1 \
  && fail "stream-loop.sh --bogus exited 0 — unknown flags must be rejected"
grep -q "unknown flag '--bogus'" /tmp/dry-run-bogus.txt \
  || fail "unknown-flag error message missing"
pass "unknown flag rejected (exit 2, error names the flag)"

bash scripts/stream-loop.sh positional > /tmp/dry-run-positional.txt 2>&1 \
  && fail "stream-loop.sh positional exited 0 — positional args must be rejected"
grep -q "unexpected argument 'positional'" /tmp/dry-run-positional.txt \
  || fail "unexpected-argument error message missing"
pass "positional argument rejected (exit 2, error names it)"

echo "ALL DRY-RUN CHECKS PASSED"
