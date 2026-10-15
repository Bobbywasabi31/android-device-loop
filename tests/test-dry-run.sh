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

grep -q 'billing guard: capping device steps' /tmp/dry-run-stdout.txt \
  || fail "billing guard did not engage on the default run"
pass "billing guard engaged by default (--max-minutes=25)"

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

# The timing log on the failure path: steps 1-2 closed normally, step 3
# (install) has no closing row — its start line stays in the console, which is
# where it died.
FSTEPS="$LATEST/steps.log"
[ -f "$FSTEPS" ] || fail "steps.log missing on the failure path"
[ "$(grep -cv '^#' "$FSTEPS")" -eq 2 ] || fail "steps.log on the failure path should hold exactly the 2 completed rows"
grep -q "step 3: install APK \.\.\." /tmp/dry-run-fail-stdout.txt \
  || fail "failure path: console missing the step 3 start line"
pass "failure path: steps.log holds the completed rows; the dead step's start line is in the console"

# --- part 4: --help + unknown flags ---------------------------------------
# A bare `stream-loop.sh` (no env) dies on the GCP_PROJECT guard with no
# guidance; --help must document usage before any requirement is enforced,
# and typos/mistakes must fail loudly instead of silently running the loop.
bash scripts/stream-loop.sh --help > /tmp/dry-run-help.txt 2>&1 \
  || fail "stream-loop.sh --help exited nonzero"
for want in GCP_PROJECT APK MODEL --dry-run --max-minutes '1. reserve'; do
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

# --- part 5: --max-minutes billing guard -----------------------------------
# Streaming minutes burn while a device is reserved. A hung adb must not pin
# the reservation forever: the guard KILLs the device steps after N minutes
# (timeout exit 124) and the EXIT trap still releases the reservation.
rm -rf artifacts
export ANDROID_MOCK_HANG_AT="wait-for-device"
set +e
bash scripts/stream-loop.sh --dry-run --max-minutes=0.05 > /tmp/dry-run-timeout-stdout.txt 2>&1
CODE=$?
set -e
unset ANDROID_MOCK_HANG_AT
[ "$CODE" -eq 124 ] || { cat /tmp/dry-run-timeout-stdout.txt >&2; fail "expected exit 124 when the billing guard fires, got $CODE"; }
pass "billing guard exits 124 on a hung adb"

LATEST="$(ls -dt artifacts/*/ 2>/dev/null | head -1)"
[ -n "$LATEST" ] || fail "no artifacts dir created on the timeout path"
grep -q '^adb wait-for-device$' "$LATEST/android-calls.log" \
  || fail "hang point (adb wait-for-device) not reached"
grep -q '^android device remote disconnect dryrun-reservation-1' "$LATEST/android-calls.log" \
  || fail "reservation not disconnected after the billing guard fired"
grep -q '^android device remote remove dryrun-reservation-1' "$LATEST/android-calls.log" \
  || fail "reservation not removed after the billing guard fired"
pass "EXIT trap released the reservation after the billing guard fired"

RES="$LATEST/mock-state/reservations.txt"
[ -f "$RES" ] || fail "mock state missing on the timeout path"
[ -s "$RES" ] && fail "reservation leaked after billing-guard timeout: $(cat "$RES")"
pass "no reservation leaked after billing-guard timeout (mock state empty)"

# --max-minutes validation: non-numeric values and a bare flag are rejected.
bash scripts/stream-loop.sh --dry-run --max-minutes=bogus > /tmp/dry-run-mm-bogus.txt 2>&1 \
  && fail "--max-minutes=bogus exited 0 — must be rejected"
grep -q "must be a non-negative number" /tmp/dry-run-mm-bogus.txt \
  || fail "bad --max-minutes error message missing"
pass "--max-minutes=bogus rejected (exit 2)"

bash scripts/stream-loop.sh --dry-run --max-minutes > /tmp/dry-run-mm-bare.txt 2>&1 \
  && fail "bare --max-minutes exited 0 — must be rejected"
pass "bare --max-minutes rejected (exit 2)"

# --max-minutes=0 disables the guard: the full loop still runs to completion.
rm -rf artifacts
bash scripts/stream-loop.sh --dry-run --max-minutes=0 > /tmp/dry-run-mm0-stdout.txt 2>&1 \
  || { cat /tmp/dry-run-mm0-stdout.txt >&2; fail "stream-loop.sh --dry-run --max-minutes=0 exited nonzero"; }
grep -q 'billing guard disabled' /tmp/dry-run-mm0-stdout.txt \
  || fail "--max-minutes=0 did not report the guard as disabled"
grep -q 'billing guard: capping' /tmp/dry-run-mm0-stdout.txt \
  && fail "--max-minutes=0 still capped the run"
pass "--max-minutes=0 disables the billing guard (loop still exits 0)"

# --- part 6: pre-flight timeout check + gtimeout fallback ------------------
# The billing guard needs coreutils `timeout`. The availability check is a
# pre-flight (before the device reservation): a machine without it must fail
# fast with exit 2 and never reserve a billed device. On macOS, Homebrew
# coreutils installs it as `gtimeout`, which the script accepts as a fallback.
command -v timeout >/dev/null \
  || fail "test env needs coreutils timeout to build the restricted PATH"
REAL_TIMEOUT="$(command -v timeout)"
RESTRICTED="$(mktemp -d)"
IFS=: read -ra PATHDIRS <<< "$PATH"
for d in "${PATHDIRS[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    b="${f##*/}"
    case "$b" in timeout|gtimeout) continue ;; esac
    [ -e "$RESTRICTED/$b" ] || ln -s "$f" "$RESTRICTED/$b" 2>/dev/null || true
  done
done
pass "built a restricted PATH without timeout/gtimeout"

rm -rf artifacts
set +e
PATH="$RESTRICTED" bash scripts/stream-loop.sh --dry-run --max-minutes=5 > /tmp/dry-run-no-timeout.txt 2>&1
CODE=$?
set -e
[ "$CODE" -eq 2 ] || { cat /tmp/dry-run-no-timeout.txt >&2; fail "expected exit 2 without timeout on PATH, got $CODE"; }
grep -q "needs coreutils 'timeout'" /tmp/dry-run-no-timeout.txt \
  || fail "missing-timeout error message absent"
grep -q "brew install coreutils" /tmp/dry-run-no-timeout.txt \
  || fail "macOS hint absent from the missing-timeout error"
pass "missing timeout fails fast (exit 2, helpful error incl. macOS hint)"

# Fail-fast must happen BEFORE the reservation: the pre-flight check fires
# before the artifacts dir is even created, so nothing must exist at all.
[ -e artifacts ] && fail "artifacts dir was created before the timeout pre-flight check"
pass "no device reserved and no side effects when timeout is unavailable (check runs pre-flight)"

# gtimeout fallback: hide `timeout`, provide a `gtimeout` shim pointing at the
# real binary — the full loop must exit 0 and the guard must use the shim.
SHIMDIR="$(mktemp -d)"
cat > "$SHIMDIR/gtimeout" <<EOF
#!/usr/bin/env bash
exec "$REAL_TIMEOUT" "\$@"
EOF
chmod +x "$SHIMDIR/gtimeout"
rm -rf artifacts
PATH="$SHIMDIR:$RESTRICTED" bash scripts/stream-loop.sh --dry-run --max-minutes=2 > /tmp/dry-run-gtimeout.txt 2>&1 \
  || { cat /tmp/dry-run-gtimeout.txt >&2; fail "gtimeout fallback: loop exited nonzero"; }
grep -q 'billing guard: capping.*via gtimeout' /tmp/dry-run-gtimeout.txt \
  || fail "guard did not report using gtimeout"
pass "gtimeout accepted as the billing-guard binary (macOS-style PATH)"

# --- part 7: per-step timing --------------------------------------------------
# Each numbered step is timed into steps.log (complements the --max-minutes
# guard: when the guard fires, the log shows which step ate the minutes).
# Uses the gtimeout run's artifacts above (guard engaged, steps ran in the
# timeout's child shell — the export -f path).
LATEST="$(ls -dt artifacts/*/ 2>/dev/null | head -1)"
[ -n "$LATEST" ] || fail "no artifacts dir for the timing checks"
STEPS="$LATEST/steps.log"
[ -f "$STEPS" ] || fail "steps.log missing"
[ "$(grep -cv '^#' "$STEPS")" -eq 5 ] || fail "steps.log should have 5 timed rows, got: $(grep -cv '^#' "$STEPS")"
[ "$(awk -F'\t' '!/^#/ {printf "%s ", $1}' "$STEPS")" = "1 2 3 4 5 " ] \
  || fail "steps.log rows are not steps 1..5 in order"
while IFS="$(printf '\t')" read -r num label start dur _; do
  case "$num" in ''|'#'*) continue ;; esac
  [ -n "$label" ] || fail "steps.log: empty label for step $num"
  case "$dur" in ''|*[!0-9]*) fail "steps.log: bad duration '$dur' for step $num" ;; esac
done < "$STEPS"
pass "steps.log has 5 ordered rows (1=reserve … 5=evidence) with integer durations"
for n in 1 2 3 4 5; do
  grep -q "step $n: .* done in [0-9]*s" /tmp/dry-run-gtimeout.txt \
    || fail "console missing 'step $n … done in Ns' line"
done
pass "console reports each step's duration"

echo "ALL DRY-RUN CHECKS PASSED"
