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

echo "== seal =="
# shellcheck disable=SC1091
source "$HERE/../setup/lib/seal.sh"
ROOT="$SANDBOX/root"
STUB="$SANDBOX/stub"
SEAL_ROOT="$ROOT"
BUNDLE_DIR="$ROOT/opt/node-setup"
CLUSTER_ENV_FILE="$SANDBOX/seal-cluster.env"
echo 'K3S_SERVER_IP="100.64.0.1"' > "$CLUSTER_ENV_FILE"
ROLE="worker"
mkdir -p "$STUB/bin" "$BUNDLE_DIR/docs" "$ROOT/root" "$ROOT/etc/systemd/system"
# The bundle's own docs name the secret keys; the scan must leave them alone.
echo 'TS_AUTHKEY=<ephemeral key>' > "$BUNDLE_DIR/docs/example.md"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$STUB/bin/$1"; chmod +x "$STUB/bin/$1"; }
stub tailscale "echo \"{\\\"BackendState\\\": \\\"\$(cat '$STUB/ts-state' 2>/dev/null || echo NeedsLogin)\\\"}\""
stub jq "sed -n 's/.*\"BackendState\": *\"\\([^\"]*\\)\".*/\\1/p'"
stub systemctl "case \"\$1\" in
  is-active)  [ -f '$STUB/k3s-active' ] ;;
  is-enabled) if [ -f '$STUB/k3s-enabled' ]; then echo enabled; else echo disabled; exit 1; fi ;;
  *)          echo \"systemctl \$*\" >> '$STUB/calls' ;;
esac"
stub docker "case \"\$1\" in
  ps)    [ ! -f '$STUB/docker-down' ] || exit 1; cat '$STUB/containers' 2>/dev/null || true ;;
  image) printf 'srv.example/browser:beta\n<none>:<none>\n' ;;
esac"
stub ufw "case \"\$1\" in
  status) printf '%s\n' '[ 1] Anywhere on tailscale0     ALLOW IN    Anywhere                   # tailnet' \
    '[ 2] 22/tcp                     ALLOW IN    203.0.113.7                # node-setup: provisioning ssh guard' \
    '[ 3] 80/tcp                     ALLOW IN    Anywhere' ;;
  *)      echo \"ufw \$*\" >> '$STUB/calls' ;;
esac"
for cmd in apt-get journalctl cloud-init fstrim; do stub "$cmd" "echo \"$cmd \$*\" >> '$STUB/calls'"; done
stub dpkg-query "echo 1.2.3"
stub k3s "echo 'k3s version v1.35.4+k3s1 (abc)'"
PATH="$STUB/bin:$PATH"

STEP_DESC[sealed-any]="prepared"; sealed-any::apply() { :; }
STEP_DESC[sealed-boot]="join"; STEP_PHASE[sealed-boot]=boot; sealed-boot::apply() { :; }
RUN_PHASE=prepare
run_steps sealed-any sealed-boot >/dev/null 2>&1
refusals() { seal_refusals sealed-any sealed-boot; }
t "a prepared, identity-free disk may be sealed" test -z "$(refusals)"
refused() { # refused "name" "expected reason fragment" setup-cmd undo-cmd
  local name="$1" want="$2" out
  eval "$3"
  out="$(refusals)"
  eval "$4"
  if grep -qF -- "$want" <<< "$out"; then PASS=$((PASS+1)); echo "  ok  seal refuses: $name"
  else FAIL=$((FAIL+1)); echo "  FAIL seal refuses: $name (got: $out)"; fi
}
refused "tailscale running"   "tailscale is logged in (BackendState Running)" "echo Running > '$STUB/ts-state'"  "rm '$STUB/ts-state'"
refused "tailscale starting"  "tailscale is logged in (BackendState Starting)" "echo Starting > '$STUB/ts-state'" "rm '$STUB/ts-state'"
refused "k3s-agent active"    "k3s-agent is active"   "touch '$STUB/k3s-active'"  "rm '$STUB/k3s-active'"
refused "k3s-agent enabled"   "k3s-agent is enabled"  "touch '$STUB/k3s-enabled'" "rm '$STUB/k3s-enabled'"
refused "registered agent"    "/etc/rancher/node/password exists" \
  "mkdir -p '$ROOT/etc/rancher/node'; touch '$ROOT/etc/rancher/node/password'" "rm -r '$ROOT/etc/rancher'"
refused "join token in the agent env" "k3s-agent.service.env holds K3S_TOKEN" \
  "echo K3S_TOKEN=x > '$ROOT/etc/systemd/system/k3s-agent.service.env'" "rm '$ROOT/etc/systemd/system/k3s-agent.service.env'"
refused "containers"          "containers exist: abc123" "echo abc123 > '$STUB/containers'" "rm '$STUB/containers'"
refused "docker unreachable"  "cannot list docker containers" "touch '$STUB/docker-down'" "rm '$STUB/docker-down'"
refused "secrets.env"         "$NODE_SETUP_CONF_DIR/secrets.env exists" \
  "echo X=1 > '$NODE_SETUP_CONF_DIR/secrets.env'" "rm '$NODE_SETUP_CONF_DIR/secrets.env'"
refused "registry login"      "/root/.docker/config.json exists" \
  "mkdir -p '$ROOT/root/.docker'; echo '{}' > '$ROOT/root/.docker/config.json'" "rm -r '$ROOT/root/.docker'"
refused "provisioning script" "/opt/burst-bake.sh exists" "touch '$ROOT/opt/burst-bake.sh'" "rm '$ROOT/opt/burst-bake.sh'"
refused "unfinished run"      "a node-setup run is unfinished" \
  "touch '$ROOT/etc/systemd/system/node-setup-resume.service'" "rm '$ROOT/etc/systemd/system/node-setup-resume.service'"
refused "secret in /etc/node-setup" "$NODE_SETUP_CONF_DIR/bake.env assigns a secret" \
  "echo '  REGISTRY_PASSWORD=x' > '$NODE_SETUP_CONF_DIR/bake.env'" "rm '$NODE_SETUP_CONF_DIR/bake.env'"
refused "secret under /root"  "/root/notes assigns a secret" \
  "echo 'export TS_AUTHKEY=tskey' > '$ROOT/root/notes'" "rm '$ROOT/root/notes'"
refused "secret under /opt"   "/opt/join.env assigns a secret" "echo 'K3S_TOKEN=K10x' > '$ROOT/opt/join.env'" "rm '$ROOT/opt/join.env'"
refused "unprepared step"     "not prepared with this bundle and cluster.env: sealed-any" \
  "echo 'K3S_SERVER_IP=\"100.64.0.2\"' > '$CLUSTER_ENV_FILE'" "echo 'K3S_SERVER_IP=\"100.64.0.1\"' > '$CLUSTER_ENV_FILE'"
t "the refusals left nothing behind"   test -z "$(refusals)"

mkdir -p "$ROOT/var/lib/tailscale" "$ROOT/var/lib/docker" "$ROOT/etc/ssh" "$ROOT/root/.ssh" "$ROOT/home/ubuntu/.ssh" \
  "$ROOT/var/lib/apt/lists" "$ROOT/var/log/apt" "$ROOT/var/lib/systemd" "$NODE_SETUP_STATE_DIR/rebooted-for"
touch "$ROOT/var/lib/tailscale/tailscaled.state" "$ROOT/var/lib/docker/engine-id" "$ROOT/var/lib/k3s-flannel-watchdog.state" \
  "$ROOT/etc/ssh/ssh_host_ed25519_key" "$ROOT/root/.ssh/authorized_keys" "$ROOT/home/ubuntu/.ssh/authorized_keys" \
  "$ROOT/root/.bash_history" "$ROOT/var/lib/apt/lists/archive_Packages" "$ROOT/var/log/apt/history.log.1.gz" \
  "$ROOT/var/log/syslog" "$ROOT/var/lib/systemd/random-seed" "$NODE_SETUP_STATE_DIR/.apt-stamp" "$NODE_SETUP_STATE_DIR/.step.abc123"
echo "old log" > "$LOG_FILE"
t "seal_image runs"                       seal_image
tf "tailscale node key removed"           test -e "$ROOT/var/lib/tailscale/tailscaled.state"
tf "docker engine id removed"             test -e "$ROOT/var/lib/docker/engine-id"
tf "watchdog state removed"               test -e "$ROOT/var/lib/k3s-flannel-watchdog.state"
tf "ssh host keys removed"                test -e "$ROOT/etc/ssh/ssh_host_ed25519_key"
tf "root authorized_keys removed"         test -e "$ROOT/root/.ssh/authorized_keys"
tf "default user authorized_keys removed" test -e "$ROOT/home/ubuntu/.ssh/authorized_keys"
tf "shell history removed"                test -e "$ROOT/root/.bash_history"
tf "apt lists removed"                    test -e "$ROOT/var/lib/apt/lists/archive_Packages"
tf "rotated logs removed"                 test -e "$ROOT/var/log/apt/history.log.1.gz"
t  "live logs kept"                       test -e "$ROOT/var/log/syslog"
tf "random seed removed"                  test -e "$ROOT/var/lib/systemd/random-seed"
tf "apt stamp removed"                    test -e "$NODE_SETUP_STATE_DIR/.apt-stamp"
tf "leftover step scripts removed"        test -e "$NODE_SETUP_STATE_DIR/.step.abc123"
tf "reboot markers removed"               test -e "$NODE_SETUP_STATE_DIR/rebooted-for"
t  "journal hashes kept"                  test -f "$NODE_SETUP_STATE_DIR/state/sealed-any.hash"
tf "setup.log truncated"                  grep -q "old log" "$LOG_FILE"
t  "image.env records the role"           grep -qx 'IMAGE_ROLE=worker' "$NODE_SETUP_CONF_DIR/image.env"
t  "image.env lists the docker images"    grep -qx 'IMAGE_DOCKER_IMAGES=srv.example/browser:beta' "$NODE_SETUP_CONF_DIR/image.env"
t  "image.env is sourceable"              bash -c "set -e; source '$NODE_SETUP_CONF_DIR/image.env'; [[ \$IMAGE_K3S == 'k3s version v1.35.4+k3s1 (abc)' ]]"
t  "services stopped"                     grep -qx "systemctl stop tailscaled" "$STUB/calls"
t  "only the ssh guard ufw rule deleted"  test "$(grep '^ufw ' "$STUB/calls")" = "ufw --force delete 2"
t  "cloud-init instance state reset"      grep -qx "cloud-init clean --logs --seed --machine-id" "$STUB/calls"
t  "the sealed disk still passes the refusals" test -z "$(refusals)"
RUN_PHASE=apply

echo "== reboot request flow (unit level) =="
request_reboot "test reason"
t "reboot flag file written"       test -f "$REBOOT_FLAG_FILE"
t "reboot reason recorded"         grep -q "test reason" "$REBOOT_FLAG_FILE"
rm -f "$REBOOT_FLAG_FILE"

echo
echo "framework tests: $PASS passed, $FAIL failed"
exit "$((FAIL > 0 ? 1 : 0))"
