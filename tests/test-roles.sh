#!/usr/bin/env bash
# Role integration tests:
#   1. bash -n syntax check on every shell file
#   2. shellcheck on the framework/CLI/modules/roles (payloads are vendored)
#   3. sandboxed --dry-run of every role x cluster combo on this host
#   4. the same dry-runs in a pristine ubuntu container (fresh-node simulation:
#      no tailscale/docker/k3s/psql binaries exist there), if docker is usable
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
INFRA="$(dirname "$HERE")"
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

MATRIX=(worker gateway control-plane db)
NODE_SETUP_RUN_DIR="$(mktemp -d)"
export NODE_SETUP_RUN_DIR
trap 'rm -rf "$NODE_SETUP_RUN_DIR"' EXIT

echo "== 1. bash -n syntax =="
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "syntax $f"; else fail "syntax $f"; bash -n "$f"; fi
done < <(find "$INFRA" -name '*.sh' -o -name 'node-setup' | grep -v '/secrets/')

echo "== 2. shellcheck =="
if command -v shellcheck >/dev/null; then
  # SC1090/SC1091: dynamic sources; SC2034: cluster env vars are consumed by
  # other sourced files; SC2317: step functions are invoked indirectly.
  SC_FILES=("$INFRA/setup/node-setup" "$INFRA/setup/lib/framework.sh"
            "$INFRA"/setup/modules/*.sh "$INFRA"/setup/roles/*.sh
            "$INFRA/setup/payloads/flannel-watchdog.sh"
            "$INFRA/setup/payloads/profile-share-ensure.sh"
            "$INFRA/setup/payloads/profiles-detach.sh"
            "$INFRA/provision.sh" "$INFRA/fleet.sh")
  if shellcheck -x -e SC1090,SC1091,SC2034,SC2317 "${SC_FILES[@]}"; then
    ok "shellcheck clean (${#SC_FILES[@]} files)"
  else
    fail "shellcheck reported issues"
  fi
else
  echo "  (shellcheck not installed; skipping)"
fi

echo "== 3. sandboxed dry-run of every role =="
for role in "${MATRIX[@]}"; do
  SB="$(mktemp -d)"
  out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
        "$INFRA/setup/node-setup" --role "$role" --dry-run --yes 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] && grep -q "dry-run complete" <<< "$out"; then
    ok "dry-run $role ($(grep -c 'WOULD apply\|up to date\|already satisfied' <<< "$out") steps)"
  else
    fail "dry-run $role (rc=$rc)"; echo "$out" | tail -5
  fi
  rm -rf "$SB"
done

echo "== 3b. --server override =="
SB="$(mktemp -d)"
out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
      "$INFRA/setup/node-setup" --role worker --server 100.99.88.77 --dry-run --yes 2>&1)"
if grep -q "control plane: 100.99.88.77" <<< "$out" \
   && grep -q 'NODE_K3S_SERVER="100.99.88.77"' "$SB/conf/node.conf"; then
  ok "--server overrides the control plane IP and persists in node.conf"
else
  fail "--server override"; echo "$out" | tail -3
fi
# persisted override must survive a re-run without the flag
out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
      "$INFRA/setup/node-setup" --role worker --dry-run --yes 2>&1)"
if grep -q "control plane: 100.99.88.77" <<< "$out"; then
  ok "persisted --server wins on re-run"
else
  fail "persisted --server lost on re-run"; echo "$out" | tail -3
fi
rm -rf "$SB"
# default from cluster.env (or the template node-setup falls back to) when no override
SB="$(mktemp -d)"
CLUSTER_ENV="$INFRA/setup/cluster.env"
[[ -f "$CLUSTER_ENV" ]] || CLUSTER_ENV="$INFRA/setup/cluster.env.example"
DEFAULT_IP="$(sed -n 's/^K3S_SERVER_IP="\(.*\)"$/\1/p' "$CLUSTER_ENV")"
out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
      "$INFRA/setup/node-setup" --role worker --dry-run --yes 2>&1)"
if [[ -n "$DEFAULT_IP" ]] && grep -qxF "[setup] control plane: $DEFAULT_IP" <<< "$out"; then
  ok "default control plane IP comes from cluster.env ($DEFAULT_IP)"
else
  fail "default control plane IP"; echo "$out" | tail -3
fi
rm -rf "$SB"

echo "== 3c. WORKER_NODE_LABELS from cluster.env =="
SB="$(mktemp -d)"
cp -a "$INFRA/setup" "$SB/setup"
cp "$SB/setup/cluster.env.example" "$SB/setup/cluster.env"
labels_of() { # labels_of role -> the "node labels:" line of a sandboxed dry-run
  NODE_SETUP_STATE_DIR="$SB/state-$1" NODE_SETUP_CONF_DIR="$SB/conf-$1" NO_COLOR=1 \
    "$SB/setup/node-setup" --role "$1" --dry-run --yes 2>&1 | sed -n 's/^\[setup\] node labels: //p'
}
labels="$(labels_of worker)"
if [[ "$labels" == "none" ]]; then
  ok "the template gives a worker no node labels"
else
  fail "template worker node labels: got '$labels', want 'none'"
fi
echo 'WORKER_NODE_LABELS=("browser.lol/burst=true" "example.com/tier=a")' >> "$SB/setup/cluster.env"
for role in worker gateway; do
  labels="$(labels_of "$role")"
  case "$role" in
    worker)  want="browser.lol/burst=true example.com/tier=a" ;;
    gateway) want="type=gateway" ;;
  esac
  if [[ "$labels" == "$want" ]]; then
    ok "$role node labels: $labels"
  else
    fail "$role node labels: got '$labels', want '$want'"
  fi
done
# The agent install must hand every label to k3s as its own --node-label,
# through the child shell the framework runs each step in.
# shellcheck disable=SC1091
exec_args="$(
  source "$SB/setup/lib/framework.sh"
  source "$SB/setup/cluster.env"
  source "$SB/setup/modules/k3s-agent.sh"
  source "$SB/setup/roles/worker.sh"
  STATE_DIR="$SB"
  require_secrets() { :; }
  ts_ip() { echo 100.64.0.9; }
  retry() { :; }
  curl() { :; }
  sh() { printf '%s\n' "$INSTALL_K3S_EXEC"; }
  _run_fn k3s-agent-install::apply
)"
want="agent --node-ip=100.64.0.9 --flannel-iface=tailscale0 --node-label=browser.lol/burst=true --node-label=example.com/tier=a"
if [[ "$exec_args" == "$want" ]]; then
  ok "k3s agent install gets one --node-label per WORKER_NODE_LABELS entry"
else
  fail "k3s agent INSTALL_K3S_EXEC: got '$exec_args', want '$want'"
fi
rm -rf "$SB"

echo "== 3d. invalid inputs are rejected =="
SB="$(mktemp -d)"
if NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" \
   "$INFRA/setup/node-setup" --role dev --dry-run --yes >/dev/null 2>&1; then
  fail "removed dev role should be rejected"
else
  ok "removed dev role rejected"
fi
if NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" \
   "$INFRA/setup/node-setup" --role worker --server not-an-ip --dry-run --yes >/dev/null 2>&1; then
  fail "non-IP --server should be rejected"
else
  ok "non-IP --server rejected"
fi
# Fresh sandbox: the runs above persisted their (invalid) node.conf.
rm -rf "$SB"; SB="$(mktemp -d)"
if NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" \
   "$INFRA/setup/node-setup" --role worker --only no-such-step --dry-run --yes >/dev/null 2>&1; then
  fail "an --only step outside the plan should be rejected"
else
  ok "--only step outside the plan rejected"
fi
if NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" \
   "$INFRA/setup/node-setup" --role worker --only session-limits --dry-run --yes >/dev/null 2>&1; then
  ok "--only step of the plan accepted"
else
  fail "an --only step of the plan should be accepted"
fi
rm -rf "$SB"; SB="$(mktemp -d)"
cp -a "$INFRA/setup" "$SB/setup"
cp "$SB/setup/cluster.env.example" "$SB/setup/cluster.env"
echo 'WORKER_NODE_LABELS=("bad label")' >> "$SB/setup/cluster.env"
if out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
          "$SB/setup/node-setup" --role worker --dry-run --yes 2>&1)"; then
  fail "a malformed WORKER_NODE_LABELS entry should be rejected"
elif grep -q "node label 'bad label' is not a Kubernetes key=value label" <<< "$out"; then
  ok "malformed WORKER_NODE_LABELS entry rejected"
else
  fail "malformed WORKER_NODE_LABELS entry failed for another reason"; echo "$out" | tail -3
fi
rm -rf "$SB"

echo "== 3e. adoption checks =="
SB="$(mktemp -d)"
# Each check runs in the framework's child process, as in a real run.
# shellcheck disable=SC1091
base_check_rc() {
  (
    source "$INFRA/setup/lib/framework.sh"
    source "$INFRA/setup/modules/base.sh"
    STATE_DIR="$SB/state"
    dpkg() { [[ ! -f "$SB/no-pkgs" ]]; }
    _run_fn base-packages::check
  ) >/dev/null 2>&1
}
mkdir -p "$SB/state/state"
if ! base_check_rc; then ok "base-packages: a fresh node runs the full upgrade"; else fail "base-packages adopted without a journal entry"; fi
echo stale > "$SB/state/state/base-packages.hash"
if base_check_rc; then ok "base-packages: a journaled node adopts on a hash change"; else fail "base-packages did not adopt"; fi
touch "$SB/no-pkgs"
if ! base_check_rc; then ok "base-packages: a missing package re-applies"; else fail "base-packages ignored a missing package"; fi
rm -rf "$SB"
# oom-guards writes under /etc/systemd/system; test its check through a copy
# whose drop-in path points into the sandbox.
SB="$(mktemp -d)"
oom_check_rc() {
  (
    source "$INFRA/setup/lib/framework.sh"
    eval "$(sed "s#/etc/systemd/system#$SB#g" "$INFRA/setup/modules/resilience.sh")"
    STATE_DIR="$SB"
    systemctl() { [[ "$1 $2" == "cat k3s-agent.service" ]]; }
    _run_fn oom-guards::check
  ) >/dev/null 2>&1
}
if ! oom_check_rc; then ok "oom-guards: an existing unit without the drop-in fails the check"; else fail "oom-guards check passed without a drop-in"; fi
mkdir -p "$SB/k3s-agent.service.d" && touch "$SB/k3s-agent.service.d/90-oom.conf"
if oom_check_rc; then ok "oom-guards: the drop-in on every existing unit passes the check"; else fail "oom-guards check failed with the drop-in"; fi
rm -rf "$SB"; SB="$(mktemp -d)"
# One sandbox, two applies: the first writes and reloads, the re-run writes
# nothing and does not reload; verify passes. The postgresql@ template gets
# its drop-in but is never asked for a live MainPID.
(
  source "$INFRA/setup/lib/framework.sh"
  eval "$(sed "s#/etc/systemd/system#$SB#g" "$INFRA/setup/modules/resilience.sh")"
  STATE_DIR="$SB"
  systemctl() {
    case "$1 ${2:-}" in
      'cat k3s-agent.service'|'cat ssh.service'|'cat postgresql@.service') return 0 ;;
      'daemon-reload '*) touch "$SB/reloaded" ;;
      'show '*) echo "${*: -1}" >> "$SB/shown"; echo 0 ;;
      *) return 1 ;;
    esac
  }
  _run_fn oom-guards::apply; echo $? > "$SB/rc1"
  [[ -f "$SB/reloaded" ]] && touch "$SB/reloaded1"
  rm -f "$SB/reloaded"
  _run_fn oom-guards::apply; echo $? > "$SB/rc2"
  _run_fn oom-guards::verify; echo $? > "$SB/rc-verify"
) >/dev/null 2>&1
if [[ "$(cat "$SB/rc1" 2>/dev/null)" == 0 && -f "$SB/reloaded1" ]] \
   && grep -qx 'OOMScoreAdjust=-900' "$SB/k3s-agent.service.d/90-oom.conf" 2>/dev/null \
   && grep -qx 'OOMScoreAdjust=-900' "$SB/ssh.service.d/90-oom.conf" 2>/dev/null \
   && grep -qx 'OOMScoreAdjust=-900' "$SB/postgresql@.service.d/90-oom.conf" 2>/dev/null \
   && [[ ! -e "$SB/docker.service.d" ]]; then
  ok "oom-guards: apply succeeds, reloads systemd, writes the drop-in for every existing guarded unit and none for absent ones"
else
  fail "oom-guards apply: rc=$(cat "$SB/rc1" 2>/dev/null) reloaded=$([[ -f "$SB/reloaded1" ]] && echo yes || echo no) drop-ins: $(cd "$SB" && find . -name 90-oom.conf | sort | tr '\n' ' ')"
fi
if [[ "$(cat "$SB/rc2" 2>/dev/null)" == 0 && ! -e "$SB/reloaded" ]]; then
  ok "oom-guards: a re-run writes nothing, does not reload systemd and succeeds"
else
  fail "oom-guards re-run: rc=$(cat "$SB/rc2" 2>/dev/null) reloaded=$([[ -e "$SB/reloaded" ]] && echo yes || echo no)"
fi
if [[ "$(cat "$SB/rc-verify" 2>/dev/null)" == 0 ]]; then ok "oom-guards: verify passes after apply"; else fail "oom-guards verify failed after apply"; fi
if grep -qx 'k3s-agent.service' "$SB/shown" 2>/dev/null && ! grep -q '^postgresql@' "$SB/shown"; then
  ok "oom-guards: the live-PID pass skips the postgresql@ template"
else
  fail "oom-guards live-PID pass queried: $(tr '\n' ' ' < "$SB/shown" 2>/dev/null)"
fi
rm -rf "$SB"

echo "== 3f. alt-tailscale-port runs right after the tailnet join =="
SB="$(mktemp -d)"
out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
      "$INFRA/setup/node-setup" steps --role worker --modules alt-tailscale-port 2>&1)"
if grep -A1 -w 'tailscale-up' <<< "$out" | grep -qw 'tailscale-alt-port'; then
  ok "tailscale-alt-port follows tailscale-up"
else
  fail "tailscale-alt-port placement"; echo "$out" | tail -5
fi
rm -rf "$SB"

echo "== 3g. profile-share =="
export PROFILE_SHARE_EXPORT="10.88.0.5:/shares/abc" PROFILE_SHARE_DOMAIN="prod-location-7"
SERVER_EXPORT="127.0.0.1:/srv/browser-profile-share"
SB="$(mktemp -d)"
ns() { # ns <args...>: node-setup in a fresh sandbox, output on stdout, its rc
  local box rc
  box="$(mktemp -d "$SB/run.XXXXXX")"
  NODE_SETUP_STATE_DIR="$box/state" NODE_SETUP_CONF_DIR="$box/conf" NO_COLOR=1 \
    "$INFRA/setup/node-setup" "$@" 2>&1
  rc=$?
  return "$rc"
}
plan_of() { ns steps --role worker --modules "$1" | awk '{print $1}' | tr '\n' ' '; }
plan="$(plan_of direct-egress,profile-share)"
if [[ "$plan" == *"session-isolation profile-share-kernel profile-share-scratch profile-share-mount profile-share-units k3s-agent-install "* \
      && "$plan" == *" direct-egress " && "$plan" != *exitnode-routing* ]]; then
  ok "profile-share steps run before the agent joins; direct-egress stays last"
else
  fail "profile-share step order: $plan"
fi
plan="$(PROFILE_SHARE_EXPORT="$SERVER_EXPORT" PROFILE_SHARE_DOMAIN=beta-location-3 plan_of profile-share,profile-share-server)"
if [[ "$plan" == *"profile-share-kernel profile-share-scratch profile-share-export profile-share-mount profile-share-units k3s-agent-install "* ]]; then
  ok "profile-share-server exports before the mount"
else
  fail "profile-share-server step order: $plan"
fi
if out="$(ns --role worker --modules profile-share --dry-run --yes)" && grep -q "dry-run complete" <<< "$out"; then
  ok "dry-run profile-share with default sizes"
else
  fail "dry-run profile-share"; echo "$out" | tail -5
fi
if out="$(PROFILE_SHARE_EXPORT="$SERVER_EXPORT" PROFILE_SHARE_DOMAIN=beta-location-3 PROFILE_SCRATCH_GIB=6 PROFILE_SHARE_SERVER_GIB=16 \
          ns --role worker --modules profile-share,profile-share-server --dry-run --yes)" \
   && grep -q "dry-run complete" <<< "$out"; then
  ok "dry-run profile-share-server with overridden sizes"
else
  fail "dry-run profile-share-server"; echo "$out" | tail -5
fi
refused() { # refused <label> <expected message part> <env...> -- <node-setup args...>
  local label="$1" want="$2" envs=() out
  shift 2
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  if out="$(for e in "${envs[@]}"; do export "${e?}"; done; ns "$@")"; then
    fail "$label should be refused"
  elif grep -qF -- "$want" <<< "$out"; then
    ok "$label refused"
  else
    fail "$label refused for another reason"; echo "$out" | tail -3
  fi
}
W=(--role worker --modules profile-share --dry-run --yes)
refused "a missing PROFILE_SHARE_DOMAIN" "PROFILE_SHARE_DOMAIN ''" PROFILE_SHARE_DOMAIN= -- "${W[@]}"
refused "a missing PROFILE_SHARE_EXPORT" "PROFILE_SHARE_EXPORT ''" PROFILE_SHARE_EXPORT= -- "${W[@]}"
refused "a 192.168.1.5 export" "must be <10.x.y.z|127.0.0.1>" PROFILE_SHARE_EXPORT=192.168.1.5:/x -- "${W[@]}"
refused "a 10.42.0.9 export" "outside 10.42.0.0/16" PROFILE_SHARE_EXPORT=10.42.0.9:/x -- "${W[@]}"
refused "a bad domain" "must match (prod|beta)-location-<id>" PROFILE_SHARE_DOMAIN=prod-gra11 -- "${W[@]}"
refused "PROFILE_SCRATCH_GIB=3" "PROFILE_SCRATCH_GIB '3'" PROFILE_SCRATCH_GIB=3 -- "${W[@]}"
refused "PROFILE_SHARE_SERVER_GIB=x" "PROFILE_SHARE_SERVER_GIB 'x'" PROFILE_SHARE_EXPORT="$SERVER_EXPORT" PROFILE_SHARE_SERVER_GIB=x \
  -- --role worker --modules profile-share,profile-share-server --dry-run --yes
refused "profile-share-server without profile-share" "requires profile-share" PROFILE_SHARE_EXPORT="$SERVER_EXPORT" \
  -- --role worker --modules profile-share-server --dry-run --yes
refused "a loopback export without profile-share-server" "needs the profile-share-server module" PROFILE_SHARE_EXPORT="$SERVER_EXPORT" -- "${W[@]}"
refused "profile-share on a gateway" "worker role only" -- --role gateway --modules profile-share --dry-run --yes

# shellcheck disable=SC1091
share_helpers() { # runs "$@" with the module's helpers sourced and ip/df stubbed
  (
    export NODE_SETUP_STATE_DIR="$SB/state"
    source "$INFRA/setup/lib/framework.sh"
    source "$INFRA/setup/modules/profile-share.sh"
    source "$INFRA/setup/modules/profile-share-server.sh"
    ip() {
      case "$*" in
        "-o route get 10.88.0.5") echo "10.88.0.5 dev ens4 src 10.88.0.20 uid 0" ;;
        "-o route get 10.1.2.3") echo "10.1.2.3 via 51.1.1.1 dev ens3 src 51.1.1.9 uid 0" ;;
        "-o route get 10.9.0.5") echo "10.9.0.5 dev ens5 src 10.9.0.20 uid 0" ;;
        "-o route get 127.0.0.1") echo "local 127.0.0.1 dev lo table local src 127.0.0.1 uid 0" ;;
        "-o route get "*) echo "${4} dev ens4 uid 0" ;;
        "-o route show default") printf '%s\n' "default via 51.1.1.1 dev ens3 proto dhcp" "default via 10.9.0.1 dev ens5 metric 900" ;;
      esac
    }
    df() { printf 'Avail\n%s\n' "${STUB_AVAIL:-0}"; }
    "$@"
  ) >/dev/null 2>&1
}
if share_helpers _share_ip_ok 10.88.0.5 && share_helpers _share_ip_ok 127.0.0.1; then
  ok "_share_ip_ok accepts a private-NIC share and loopback"
else
  fail "_share_ip_ok refused a valid share address"
fi
for bad in 10.42.0.9 10.43.1.1 192.168.1.5 10.1.2.3 10.9.0.5; do
  if share_helpers _share_ip_ok "$bad"; then fail "_share_ip_ok accepted $bad"; else ok "_share_ip_ok refuses $bad"; fi
done
gate() { # gate <avail> <server 0|1>
  STUB_AVAIL="$1" share_helpers eval "PROFILE_SCRATCH_IMG=$SB/none.img PROFILE_SHARE_SERVER_IMG=$SB/none2.img PROFILE_SCRATCH_GIB=24 PROFILE_SHARE_SERVER_GIB=40 PROFILE_SHARE_SERVER=$2; _profile_disk_gate"
}
if gate 44 0 && ! gate 43 0 && gate 84 1 && ! gate 83 1; then
  ok "disk gate: missing images plus a 20 GiB floor"
else
  fail "disk gate thresholds"
fi
touch "$SB/none.img"
if gate 60 1 && ! gate 59 1; then ok "disk gate: an existing image counts 0"; else fail "disk gate with an existing image"; fi
printf 'keep\n# BEGIN node-setup x\nold\n# END node-setup x\n' > "$SB/fstab"
if share_helpers _ps_block_is "$SB/fstab" "node-setup x" old && ! share_helpers _ps_block_is "$SB/fstab" "node-setup x" new; then
  ok "_ps_block_is compares a managed block"
else
  fail "_ps_block_is"
fi
# Without jq on the test host a stub prints what `jq -cn` prints.
JQ_STUB=""
if ! command -v jq >/dev/null; then
  # shellcheck disable=SC2016 # evaluated in the helper shell
  JQ_STUB='jq() { local d c h; while (( $# )); do case "$1" in --arg) case "$2" in d) d=$3;; c) c=$3;; h) h=$3;; esac; shift 3;; *) shift;; esac; done; printf "{\"domain\":\"%s\",\"createdAt\":\"%s\",\"createdBy\":\"%s\"}\n" "$d" "$c" "$h"; };'
fi
mkdir -p "$SB/share"
share_helpers eval "$JQ_STUB PROFILE_SHARE_MOUNT=$SB/share PROFILE_SHARE_DOMAIN=beta-location-3; _ps_write_marker"
share_helpers eval "$JQ_STUB PROFILE_SHARE_MOUNT=$SB/share PROFILE_SHARE_DOMAIN=beta-location-9; _ps_write_marker"
marker="$(cat "$SB/share/.browser-profile-share.json" 2>/dev/null)"
if [[ "$marker" =~ ^\{\"domain\":\"beta-location-3\",\"createdAt\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\",\"createdBy\":\"[^\"]+\"\}$ ]] \
   && [[ "$(stat -c %a "$SB/share/.browser-profile-share.json")" == 644 ]]; then
  ok "share marker: written once (O_EXCL), {domain,createdAt,createdBy}, 0644"
else
  fail "share marker: $marker"
fi
rm -rf "$SB"
unset PROFILE_SHARE_EXPORT PROFILE_SHARE_DOMAIN

echo "== 3h. profile-share images and mount points (root + loop devices) =="
if [[ "$(id -u)" == 0 ]] && losetup -f >/dev/null 2>&1 && command -v mkfs.ext4 >/dev/null; then
  SB="$(mktemp -d)"
  img_helpers() { # sizes in 16 MiB units instead of GiB
    (
      export NODE_SETUP_STATE_DIR="$SB/state"
      source "$INFRA/setup/lib/framework.sh"
      source "$INFRA/setup/modules/profile-share.sh"
      PROFILE_SHARE_GIB_BYTES=16777216 PROFILE_SCRATCH_IMG="$SB/scratch.img" PROFILE_SCRATCH_GIB=4
      df() { printf 'Avail\n999\n'; }
      _run_fn "$*"
    ) >/dev/null 2>&1
  }
  mkdir -p "$SB/mnt"
  if img_helpers _ps_image "$SB/scratch.img" 4 brl-scratch \
     && [[ "$(stat -c %s "$SB/scratch.img")" == 67108864 && "$(blkid -p -s LABEL -o value "$SB/scratch.img")" == brl-scratch ]] \
     && [[ ! -e "$SB/scratch.img.tmp" ]]; then
    ok "image: created at the fixed size, ext4, labelled"
  else
    fail "image creation"
  fi
  fallocate -p -o 33554432 -l 1048576 "$SB/scratch.img"
  img_helpers _ps_image "$SB/scratch.img" 4 brl-scratch
  read -r blocks bsize < <(stat -c '%b %B' "$SB/scratch.img")
  if (( blocks * bsize >= 67108864 )); then ok "image: a re-run re-allocates a punched hole"; else fail "image stays sparse after a re-run"; fi
  if img_helpers _ps_image "$SB/scratch.img" 5 brl-scratch; then fail "image: a size change should be refused"; else ok "image: a size change is refused"; fi
  if img_helpers _ps_mount_point "$SB/mnt" && lsattr -d "$SB/mnt" 2>/dev/null | cut -d' ' -f1 | grep -q i; then
    ok "mount point: empty and unmounted -> immutable"
  else
    fail "mount point immutable flag"
  fi
  mount -o loop "$SB/scratch.img" "$SB/mnt"
  if img_helpers _ps_image_ok "$SB/scratch.img" 4 "$SB/mnt" && img_helpers _ps_mount_point "$SB/mnt"; then
    ok "image: mounted on a loop backed by the image, fully allocated"
  else
    fail "image check on the mounted image"
  fi
  if img_helpers _ps_image_ok "$SB/scratch.img" 5 "$SB/mnt"; then fail "image check accepted a wrong size"; else ok "image check refuses a wrong size"; fi
  umount "$SB/mnt"
  chattr -i "$SB/mnt"
  mkdir -p "$SB/full" && touch "$SB/full/x"
  if img_helpers _ps_mount_point "$SB/full"; then fail "mount point: a non-empty directory should be refused"; else ok "mount point: a non-empty unmounted directory is refused"; fi
  rm -rf "$SB"
else
  echo "  (needs root and a free loop device; skipping)"
fi

echo "== 4. pristine-container dry-run (fresh node simulation) =="
if docker info >/dev/null 2>&1; then
  IMG="ubuntu:24.04"
  docker pull -q "$IMG" >/dev/null 2>&1 || true
  if docker image inspect "$IMG" >/dev/null 2>&1; then
    STAGE="$(mktemp -d)"
    cp -a "$INFRA/setup" "$STAGE/setup"
    mkdir -p "$STAGE/manifests"
    SCRIPT='set -u; pass=0; fail=0
      for role in worker gateway control-plane db; do
        if /bundle/setup/node-setup --role "$role" --dry-run --yes >/tmp/out 2>&1 \
           && grep -q "dry-run complete" /tmp/out; then
          echo "  ok  container dry-run $role"; pass=$((pass+1))
        else
          echo "  FAIL container dry-run $role"; tail -5 /tmp/out; fail=$((fail+1))
        fi
      done
      echo "container: $pass ok, $fail failed"; [ "$fail" = 0 ]'
    if docker run --rm -v "$STAGE:/bundle:ro" "$IMG" bash -c "$SCRIPT"; then
      ok "pristine container dry-runs"
    else
      fail "pristine container dry-runs"
    fi
    rm -rf "$STAGE"
  else
    echo "  (cannot pull $IMG; skipping container test)"
  fi
else
  echo "  (docker unavailable; skipping container test)"
fi

echo
echo "role tests: $PASS passed, $FAIL failed"
exit "$((FAIL > 0 ? 1 : 0))"
