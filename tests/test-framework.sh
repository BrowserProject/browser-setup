#!/usr/bin/env bash
# Unit tests for setup/lib/framework.sh: journaling, idempotency,
# definition-hash re-runs, drift re-apply, dry-run, doctor, file helpers.
# Runs entirely in a sandbox (no root, no system changes).
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export NODE_SETUP_STATE_DIR="$SANDBOX/state"
export NODE_SETUP_CONF_DIR="$SANDBOX/conf"
export NO_COLOR=1
mkdir -p "$NODE_SETUP_STATE_DIR" "$NODE_SETUP_CONF_DIR"

# shellcheck disable=SC1091
source "$HERE/../setup/lib/framework.sh"
VERSIONS_FILE="$SANDBOX/versions.env"
echo 'TESTVER=1' > "$VERSIONS_FILE"
ASSUME_YES=1

PASS=0 FAIL=0
t() { # t "name" cmd... (expects success)
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok  $name";
  else FAIL=$((FAIL+1)); echo "  FAIL $name"; fi
}
tf() { # tf "name" cmd... (expects failure)
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  FAIL $name (expected failure)";
  else PASS=$((PASS+1)); echo "  ok  $name"; fi
}

echo "== file helpers =="
F="$SANDBOX/file.txt"
wic() { echo "$1" | write_if_changed "$F"; }
t  "write_if_changed writes new file"        wic hi
tf "write_if_changed same content -> rc 1"   wic hi
t  "write_if_changed new content -> rc 0"    wic hi2

ensure_line "$F" "line-a"
ensure_line "$F" "line-a"
t "ensure_line appends once" test "$(grep -c 'line-a' "$F")" = "1"

B="$SANDBOX/block.txt"
echo "keep-me" > "$B"
echo "v1" | replace_block "$B" "test block"
echo "v1" | replace_block "$B" "test block" && { echo "  FAIL replace_block same content should rc 1"; FAIL=$((FAIL+1)); } || { echo "  ok  replace_block same content rc 1"; PASS=$((PASS+1)); }
echo "v2" | replace_block "$B" "test block"
t "replace_block keeps other lines"   grep -q "keep-me" "$B"
t "replace_block updated content"     grep -q "v2" "$B"
tf "replace_block old content gone"   grep -q "v1" "$B"
t "replace_block exactly one block"   test "$(grep -c 'BEGIN test block' "$B")" = "1"

echo "== step runner: apply + journal =="
APPLIED="$SANDBOX/applied-count"
echo 0 > "$APPLIED"
STEP_DESC[s1]="test step"
s1::check() { [[ -f "$SANDBOX/s1-done" ]]; }
s1::apply() { touch "$SANDBOX/s1-done"; echo $(( $(cat "$APPLIED") + 1 )) > "$APPLIED"; }
s1::verify() { [[ -f "$SANDBOX/s1-done" ]]; }

t "first run applies"              run_steps s1
t "apply ran once"                 test "$(cat "$APPLIED")" = "1"
t "journal entry written"          test -f "$NODE_SETUP_STATE_DIR/state/s1.hash"
t "second run skips"               run_steps s1
t "apply still ran once"           test "$(cat "$APPLIED")" = "1"

echo "== drift detection =="
rm "$SANDBOX/s1-done"   # break the desired state; journal still says done
t "drift run re-applies"           run_steps s1
t "apply ran twice"                test "$(cat "$APPLIED")" = "2"

echo "== definition change re-runs =="
s1::apply() { touch "$SANDBOX/s1-done"; echo $(( $(cat "$APPLIED") + 10 )) > "$APPLIED"; }
# check still passes (s1-done exists), but hash changed -> check passes -> skip?
# No: hash mismatch + check passes = adopt (re-journal) without re-apply.
t "changed def + satisfied check adopts" run_steps s1
t "no re-apply when check passes"  test "$(cat "$APPLIED")" = "2"
rm "$SANDBOX/s1-done"
t "changed def + failed check applies" run_steps s1
t "new apply body ran"             test "$(cat "$APPLIED")" = "12"

echo "== versions.env change re-runs =="
rm "$SANDBOX/s1-done"
echo 'TESTVER=2' > "$VERSIONS_FILE"
t "versions bump re-applies"       run_steps s1
t "apply count bumped"             test "$(cat "$APPLIED")" = "22"

echo "== cluster.env change re-runs =="
CLUSTER_ENV_FILE="$SANDBOX/cluster.env"
echo 'CONF=a' > "$CLUSTER_ENV_FILE"
run_steps s1 >/dev/null 2>&1   # journal under the new hash (adopts; s1-done exists)
rm "$SANDBOX/s1-done"
echo 'CONF=b' > "$CLUSTER_ENV_FILE"
t "cluster.env change re-applies"  run_steps s1
t "apply count bumped again"       test "$(cat "$APPLIED")" = "32"
CLUSTER_ENV_FILE=""

echo "== step processes see every variable =="
_UNDERSCORE_UNITS=(a b)
UIDS_LIKE="kept"
STEP_DESC[vars]="reads globals"
vars::apply() { printf '%s %s\n' "${_UNDERSCORE_UNITS[*]}" "$UIDS_LIKE" > "$SANDBOX/vars-seen"; }
t "step with globals runs"         run_steps vars
t "_-prefixed and special-prefixed names reach the step" test "$(cat "$SANDBOX/vars-seen")" = "a b kept"

echo "== failing verify aborts =="
STEP_DESC[bad]="failing step"
bad::apply() { :; }
bad::verify() { false; }
tf "verify failure -> non-zero"    run_steps bad
tf "no journal for failed step"    test -f "$NODE_SETUP_STATE_DIR/state/bad.hash"

echo "== failing apply aborts =="
STEP_DESC[boom]="apply blows up mid-way"
boom::apply() { false; touch "$SANDBOX/boom-after-failure"; }
tf "apply failure -> non-zero"     run_steps boom
tf "fail-fast inside apply"        test -f "$SANDBOX/boom-after-failure"

echo "== dry run =="
DRY_RUN=1
STEP_DESC[dry]="dry step"
dry::apply() { touch "$SANDBOX/dry-ran"; }
t "dry run exits 0"                run_steps dry
tf "dry run does not apply"        test -f "$SANDBOX/dry-ran"
DRY_RUN=0

echo "== only/skip selection =="
STEP_DESC[sel-a]="a"; sel-a::apply() { touch "$SANDBOX/sel-a"; }
STEP_DESC[sel-b]="b"; sel-b::apply() { touch "$SANDBOX/sel-b"; }
ONLY_STEPS="sel-b"
t "only: selected runs"            run_steps sel-a sel-b
tf "only: unselected skipped"      test -f "$SANDBOX/sel-a"
t "only: selected applied"         test -f "$SANDBOX/sel-b"
ONLY_STEPS=""
SKIP_STEPS="sel-a"
t "skip: run ok"                   run_steps sel-a
tf "skip: skipped step not run"    test -f "$SANDBOX/sel-a"
SKIP_STEPS=""

echo "== phases =="
PHASE_LOG="$SANDBOX/phase-log"
STEP_DESC[ph-any]="any phase";  ph-any::apply()  { echo any  >> "$PHASE_LOG"; }
STEP_DESC[ph-boot]="boot phase"; ph-boot::apply() { echo boot >> "$PHASE_LOG"; }
STEP_DESC[ph-bake]="bake phase"; ph-bake::apply() { echo bake >> "$PHASE_LOG"; }
STEP_PHASE[ph-boot]=boot
STEP_PHASE[ph-bake]=bake
RUN_PHASE=prepare
OUT="$(run_steps ph-any ph-boot ph-bake 2>&1)"
t "prepare applies the any and bake steps"  test "$(paste -sd' ' "$PHASE_LOG")" = "any bake"
t "prepare logs why the boot step is skipped" grep -qF "[ph-boot] skipped (boot phase)" <<< "$OUT"
tf "prepare journals no boot step"         test -f "$NODE_SETUP_STATE_DIR/state/ph-boot.hash"
rm -f "$PHASE_LOG"
RUN_PHASE=apply
OUT="$(run_steps ph-any ph-boot ph-bake 2>&1)"
t "apply after prepare runs only the boot step" test "$(paste -sd' ' "$PHASE_LOG")" = "boot"
t "apply logs why the bake step is skipped" grep -qF "[ph-bake] skipped (bake phase)" <<< "$OUT"
tf "doctor leaves out the bake step"       grep -q "^ph-bake" <<< "$(doctor_steps ph-any ph-bake 2>/dev/null)"

echo "== prepared journal in a later process (image boot) =="
# Each run is a fresh bash process that sources the framework again, as a
# node booted from the image does; the step hashes must match across them.
IMG="$SANDBOX/img"
mkdir -p "$IMG/state" "$IMG/conf" "$IMG/count"
echo 'K3S_SERVER_IP="100.64.0.1"' > "$IMG/cluster.env"
cat > "$IMG/steps.sh" <<'EOF'
count() { echo $(( $(cat "$IMG/count/$1" 2>/dev/null || echo 0) + 1 )) > "$IMG/count/$1"; }
STEP_DESC[img-checked]="has a check";    STEP_DESC[img-unchecked]="no check"
STEP_DESC[img-boot]="join";              STEP_DESC[img-bake]="bake only"
STEP_PHASE[img-boot]=boot;               STEP_PHASE[img-bake]=bake
img-checked::check()  { [[ -f "$IMG/checked-state" ]]; }
img-checked::apply()  { touch "$IMG/checked-state"; count img-checked; }
img-unchecked::apply() { count img-unchecked; }
img-boot::apply()     { count img-boot; }
img-bake::apply()     { count img-bake; }
EOF
cat > "$IMG/run.sh" <<EOF
source "$HERE/../setup/lib/framework.sh"
IMG="$IMG"
VERSIONS_FILE="$VERSIONS_FILE"
CLUSTER_ENV_FILE="$IMG/cluster.env"
source "$IMG/steps.sh"
RUN_PHASE="\$1"
run_steps img-checked img-unchecked img-boot img-bake
EOF
img_run() { NODE_SETUP_STATE_DIR="$IMG/state" NODE_SETUP_CONF_DIR="$IMG/conf" bash "$IMG/run.sh" "$1"; }
counts() { local s out=""; for s in img-checked img-unchecked img-boot img-bake; do out+="$(cat "$IMG/count/$s" 2>/dev/null || echo 0) "; done; echo "${out% }"; }
t "prepare run succeeds"                   img_run prepare
t "prepare applied all but the boot step"  test "$(counts)" = "1 1 0 1"
t "boot run succeeds"                      img_run apply
t "boot run applied only the boot step"    test "$(counts)" = "1 1 1 1"
rm "$IMG/checked-state"
t "drift run succeeds"                     img_run apply
t "drift re-applies the checked step"      test "$(counts)" = "2 1 1 1"
echo 'K3S_SERVER_IP="100.64.0.2"' > "$IMG/cluster.env"
t "changed cluster.env run succeeds"       img_run apply
t "hash change: check adopts, no check re-applies" test "$(counts)" = "2 2 2 1"

echo "== doctor =="
OUT="$(doctor_steps s1 2>/dev/null)"
t "doctor lists step"              grep -q "^s1" <<< "$OUT"
t "doctor ok when healthy"         doctor_steps s1
rm "$SANDBOX/s1-done"
tf "doctor fails on drift"         doctor_steps s1

echo "== reboot request flow (unit level) =="
request_reboot "test reason"
t "reboot flag file written"       test -f "$REBOOT_FLAG_FILE"
t "reboot reason recorded"         grep -q "test reason" "$REBOOT_FLAG_FILE"
rm -f "$REBOOT_FLAG_FILE"

echo
echo "framework tests: $PASS passed, $FAIL failed"
exit "$((FAIL > 0 ? 1 : 0))"
