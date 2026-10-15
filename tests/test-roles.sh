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
# Step scripts of every sandboxed run go here instead of this host's /run.
NODE_SETUP_RUN_DIR="$(mktemp -d)"
export NODE_SETUP_RUN_DIR
trap 'rm -rf "$NODE_SETUP_RUN_DIR"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

MATRIX=(worker gateway control-plane db)

echo "== 1. bash -n syntax =="
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "syntax $f"; else fail "syntax $f"; bash -n "$f"; fi
done < <(find "$INFRA" -name '*.sh' -o -name 'node-setup' | grep -v '/secrets/')

echo "== 2. shellcheck =="
if command -v shellcheck >/dev/null; then
  # SC1090/SC1091: dynamic sources; SC2034: cluster env vars are consumed by
  # other sourced files; SC2317: step functions are invoked indirectly.
  SC_FILES=("$INFRA/setup/node-setup" "$INFRA/setup/lib/framework.sh" "$INFRA/setup/lib/seal.sh"
            "$INFRA"/setup/modules/*.sh "$INFRA"/setup/roles/*.sh
            "$INFRA/setup/payloads/flannel-watchdog.sh"
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
  K3S_INSTALLER_CACHE="$SB/no-cached-installer"
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

echo "== 3f. --prepare (disk image bake) =="
SB="$(mktemp -d)"
ns() { # ns args... -> sandboxed node-setup, output on stdout
  NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 "$INFRA/setup/node-setup" "$@" 2>&1
}
# shellcheck disable=SC1091
source "$HERE/seal-stubs.sh"
ns_seal() { # ns_seal args... -> node-setup seal on a sandbox root with stubbed host commands
  seal_stubs "$SB/root/stub"
  NODE_SETUP_SEAL_ROOT="$SB/root" PATH="$SB/root/stub/bin:$PATH" ns seal "$@"
}
steps_prepare="$(ns steps --role worker --prepare)"
steps_apply="$(ns steps --role worker)"
if grep -q '^k3s-agent-preinstall ' <<< "$steps_prepare" \
   && ! grep -qE '^(tailscale-up|k3s-agent-install) ' <<< "$steps_prepare"; then
  ok "steps --prepare lists the bake steps and no boot step"
else
  fail "steps --prepare"; echo "$steps_prepare"
fi
if grep -qE '^tailscale-up +boot ' <<< "$steps_apply" && ! grep -q '^k3s-agent-preinstall ' <<< "$steps_apply"; then
  ok "steps lists the boot steps with their phase and no bake step"
else
  fail "steps without --prepare"; echo "$steps_apply"
fi
out="$(ns --role worker --prepare --dry-run --yes)"
if grep -q "dry-run complete" <<< "$out" \
   && grep -qF "[tailscale-up] skipped (boot phase)" <<< "$out" \
   && grep -qF "[k3s-agent-install] skipped (boot phase)" <<< "$out" \
   && grep -qF "[k3s-agent-preinstall] WOULD apply" <<< "$out"; then
  ok "worker --prepare --dry-run skips the boot steps and runs the bake steps"
else
  fail "worker --prepare --dry-run"; echo "$out" | tail -5
fi
rm -rf "$SB"; SB="$(mktemp -d)"
out="$(ns --role worker --dry-run --yes)"
if grep -qF "[k3s-agent-preinstall] skipped (bake phase)" <<< "$out"; then
  ok "a normal worker run skips the bake steps"
else
  fail "a normal worker run should skip the bake steps"; echo "$out" | tail -5
fi
for role in gateway control-plane db; do
  rm -rf "$SB"; SB="$(mktemp -d)"
  if out="$(ns --role "$role" --prepare --dry-run --yes)"; then
    fail "--prepare should be refused for $role"
  elif grep -q "cannot be prepared as a disk image" <<< "$out"; then
    ok "--prepare refused for $role"
  else
    fail "--prepare for $role failed for another reason"; echo "$out" | tail -3
  fi
done
rm -rf "$SB"; SB="$(mktemp -d)"
refused() { # refused "name" args... -> the run must fail with a phase message
  local name="$1" out; shift
  if out="$(ns "$@")"; then fail "$name should be refused"
  elif grep -q "never runs in this run" <<< "$out"; then ok "$name refused"
  else fail "$name failed for another reason"; echo "$out" | tail -3; fi
}
refused "--prepare --only tailscale-up" --role worker --prepare --only tailscale-up --dry-run --yes
refused "--only k3s-agent-preinstall without --prepare" --role worker --only k3s-agent-preinstall --dry-run --yes
if ns doctor --prepare >/dev/null; then fail "doctor --prepare should be refused"; else ok "doctor --prepare refused"; fi
if ns status --poweroff >/dev/null; then fail "--poweroff outside seal should be refused"; else ok "--poweroff outside seal refused"; fi
rm -rf "$SB"; SB="$(mktemp -d)"
if out="$(ns_seal)"; then fail "seal without a prepared node should be refused"
elif grep -q "nothing to seal" <<< "$out"; then ok "seal refuses a node without node.conf"
else fail "seal without node.conf failed for another reason"; echo "$out" | tail -3; fi
# The secret scan must stay inside the sandbox, not this host's /root and /opt.
mkdir -p "$SB/root/root" "$SB/root/opt"
ns --role worker --dry-run --yes >/dev/null
rm -rf "$SB/state"
if out="$(ns_seal)"; then fail "seal of an unprepared worker should be refused"
elif grep -q "seal refused: not prepared with this bundle and cluster.env: base-packages" <<< "$out" \
     && grep -q "nothing was changed" <<< "$out" && [[ ! -e "$SB/conf/image.env" ]]; then
  ok "seal refuses an unprepared worker and changes nothing"
else fail "seal of an unprepared worker failed for another reason"; echo "$out" | tail -3; fi
rm -rf "$SB"; SB="$(mktemp -d)"
ns --role gateway --dry-run --yes >/dev/null
if out="$(ns_seal)"; then fail "seal of a gateway should be refused"
elif grep -q "cannot be prepared as a disk image" <<< "$out"; then ok "seal refuses a role that cannot be prepared"
else fail "seal of a gateway failed for another reason"; echo "$out" | tail -3; fi
rm -rf "$SB"; SB="$(mktemp -d)"
# seal cannot be previewed or narrowed: every run flag but --poweroff is refused.
ns --role worker --dry-run --yes >/dev/null
for flags in --dry-run --resume "--only base-time" "--skip base-packages" "--role worker" "--server 100.64.0.1" "--modules deadssd"; do
  # shellcheck disable=SC2086
  if out="$(ns_seal $flags)"; then fail "seal $flags should be refused"
  elif grep -q "seal takes only --poweroff, not ${flags%% *}" <<< "$out" && [[ ! -e "$SB/root/stub/calls" ]]; then
    ok "seal $flags refused before anything ran"
  else fail "seal $flags failed for another reason"; echo "$out" | tail -3; fi
done
rm -rf "$SB"

# k3s split: the bake pre-installs without any join value, the boot join reuses
# the cached installer and binary.
SB="$(mktemp -d)"
mkdir -p "$SB/bin"
cat > "$SB/bin/sh" <<'EOF'
#!/bin/bash
printf 'script=%s token=%s url=%s enable=%s start=%s download=%s exec=%s\n' "$1" "${K3S_TOKEN:-unset}" "${K3S_URL:-unset}" \
  "${INSTALL_K3S_SKIP_ENABLE:-}" "${INSTALL_K3S_SKIP_START:-}" "${INSTALL_K3S_SKIP_DOWNLOAD:-}" "$INSTALL_K3S_EXEC"
EOF
chmod +x "$SB/bin/sh"
# shellcheck disable=SC1091
k3s_step() { # k3s_step step installed-version -> what the installer was run with
  (
    source "$INFRA/setup/lib/framework.sh"
    source "$INFRA/setup/versions.env"
    source "$INFRA/setup/modules/k3s-agent.sh"
    STATE_DIR="$SB"
    K3S_INSTALLER_CACHE="$SB/k3s-install.sh"
    K3S_NODE_LABELS=()
    export K3S_URL="https://100.64.0.1:6443"
    INSTALLED="$2"
    export K3S_TOKEN="from-secrets"
    PATH="$SB/bin:$PATH"
    systemctl() { [[ -n "${JOINED:-}" && "$1" == is-active ]]; }
    k3s() { [[ -n "$INSTALLED" ]] && echo "k3s version $INSTALLED (abc)"; }
    curl() { [[ "$*" != *" -o "* ]] || echo installer > "$K3S_INSTALLER_CACHE"; }
    require_secrets() { :; }
    ts_ip() { echo 100.64.0.9; }
    retry() { :; }
    _run_fn "$1::apply"
  ) 2>&1
}
pin="$(sed -n 's/^K3S_VERSION="\(.*\)"$/\1/p' "$INFRA/setup/versions.env")"
out="$(k3s_step k3s-agent-preinstall "")"
if [[ "$out" == "script=$SB/k3s-install.sh token=unset url=unset enable=true start=true download= exec=agent --flannel-iface=tailscale0" ]]; then
  ok "k3s-agent-preinstall caches the installer and runs it without a join value, disabled"
else
  fail "k3s-agent-preinstall ran: $out"
fi
out="$(k3s_step k3s-agent-install "$pin")"
if [[ "$out" == "script=$SB/k3s-install.sh token=from-secrets url=https://100.64.0.1:6443 enable= start= download=true exec=agent --node-ip=100.64.0.9 --flannel-iface=tailscale0" ]]; then
  ok "k3s-agent-install joins through the cached installer when the pinned binary is present"
else
  fail "k3s-agent-install with a cached installer ran: $out"
fi
out="$(k3s_step k3s-agent-install "v0.0.1+k3s1")"
if [[ "$out" == "script=- token=from-secrets url=https://100.64.0.1:6443 enable= start= download= exec=agent --node-ip=100.64.0.9 --flannel-iface=tailscale0" ]]; then
  ok "k3s-agent-install downloads when the binary is not the pinned one"
else
  fail "k3s-agent-install with another binary ran: $out"
fi
out="$(JOINED=1 k3s_step k3s-agent-preinstall "$pin")"
if grep -q "pre-install is for a fresh image bake only" <<< "$out" && ! grep -q "^script=" <<< "$out"; then
  ok "k3s-agent-preinstall refuses a host whose agent has joined"
else
  fail "k3s-agent-preinstall on a joined host ran: $out"
fi
rm -rf "$SB"

echo "== 3g. browser-images-prefetch =="
SB="$(mktemp -d)"
# shellcheck disable=SC1091
prefetch() { # prefetch step-fn BAKE_IMAGES [REGISTRY_SERVER] -> rc; docker calls in $SB/docker.log
  (
    source "$INFRA/setup/lib/framework.sh"
    source "$INFRA/setup/modules/browser-images.sh"
    STATE_DIR="$SB"
    RUN_DIR="$SB/run"
    BAKE_IMAGES="$2"
    if [[ -n "${3:-}" ]]; then REGISTRY_SERVER="$3"; REGISTRY_USER="burst-bake"; REGISTRY_PASSWORD="pw-secret"; fi
    docker() {
      case "$1" in
        login)  cat > "$DOCKER_CONFIG/config.json"
                [[ "$DOCKER_CONFIG" == "$RUN_DIR"/* ]] && echo "$* (tmpfs config)" >> "$SB/docker.log" ;;
        image)  grep -qxF "$3" "$SB/present" 2>/dev/null ;;
        pull)   echo "$*" >> "$SB/docker.log"; echo "$3" >> "$SB/present" ;;
        tag)    echo "$*" >> "$SB/docker.log"; echo "$3" >> "$SB/present" ;;
        *)      echo "$*" >> "$SB/docker.log" ;;
      esac
    }
    retry() { shift 2; "$@"; }
    _run_fn "$1"
  ) >"$SB/out" 2>&1
}
calls() { paste -sd'|' "$SB/docker.log" 2>/dev/null; }
reset_prefetch() { rm -rf "$SB/docker.log" "$SB/present" "$SB/run" "$SB/out"; }

prefetch browser-images-prefetch::apply "srv.zesiger.net/browser-webrtc:beta-chrome curlimages/curl:8.22.0" beta.srv.zesiger.net
want="login beta.srv.zesiger.net --username burst-bake --password-stdin (tmpfs config)"
want+="|pull -q beta.srv.zesiger.net/browser-webrtc:beta-chrome"
want+="|tag beta.srv.zesiger.net/browser-webrtc:beta-chrome srv.zesiger.net/browser-webrtc:beta-chrome"
want+="|rmi beta.srv.zesiger.net/browser-webrtc:beta-chrome"
want+="|pull -q curlimages/curl:8.22.0"
want+="|logout beta.srv.zesiger.net"
if [[ "$(calls)" == "$want" ]]; then
  ok "prefetch pulls through REGISTRY_SERVER, names the image as the catalog does, Docker Hub anonymously"
else
  fail "prefetch docker calls: got '$(calls)', want '$want'"
fi
if [[ -z "$(find "$SB/run" -mindepth 1 2>/dev/null)" ]] && ! grep -rqs pw-secret "$SB/run" "$SB/docker.log" "$SB/out"; then
  ok "prefetch leaves no registry credentials behind"
else
  fail "prefetch left credentials behind"
fi
if prefetch browser-images-prefetch::check "srv.zesiger.net/browser-webrtc:beta-chrome curlimages/curl:8.22.0"; then
  ok "prefetch check passes once every reference inspects"
else
  fail "prefetch check after the pulls"
fi
if ! prefetch browser-images-prefetch::check "srv.zesiger.net/browser-webrtc:beta-tor"; then
  ok "prefetch check fails for a missing reference"
else
  fail "prefetch check passed for a missing reference"
fi
reset_prefetch
digest="srv.zesiger.net/browser-profile-tool@sha256:$(printf '0%.0s' {1..64})"
if ! prefetch browser-images-prefetch::apply "$digest" beta.srv.zesiger.net \
   && grep -q "a digest cannot be renamed" "$SB/out" && [[ -z "$(calls)" ]]; then
  ok "prefetch refuses a digest it would have to rename, before any login"
else
  fail "prefetch with a digest on another registry: rc ok or calls '$(calls)'"
fi
reset_prefetch
if prefetch browser-images-prefetch::apply "$digest" srv.zesiger.net \
   && [[ "$(calls)" == "login srv.zesiger.net --username burst-bake --password-stdin (tmpfs config)|pull -q $digest|logout srv.zesiger.net" ]]; then
  ok "prefetch pulls a digest from its own registry unchanged"
else
  fail "prefetch with a digest on REGISTRY_SERVER: calls '$(calls)'"
fi
reset_prefetch
if prefetch browser-images-prefetch::apply "" && [[ -z "$(calls)" ]]; then
  ok "prefetch without BAKE_IMAGES needs no registry and pulls nothing"
else
  fail "prefetch without BAKE_IMAGES: calls '$(calls)'"; tail -3 "$SB/out"
fi
rm -rf "$SB"

echo "== 3d. alt-tailscale-port runs right after the tailnet join =="
SB="$(mktemp -d)"
out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
      "$INFRA/setup/node-setup" steps --role worker --modules alt-tailscale-port 2>&1)"
if grep -A1 -w 'tailscale-up' <<< "$out" | grep -qw 'tailscale-alt-port'; then
  ok "tailscale-alt-port follows tailscale-up"
else
  fail "tailscale-alt-port placement"; echo "$out" | tail -5
fi
rm -rf "$SB"

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
      rm -rf /var/lib/node-setup /etc/node-setup
      if /bundle/setup/node-setup --role worker --prepare --dry-run --yes >/tmp/out 2>&1 \
         && grep -q "dry-run complete" /tmp/out && grep -qF "[tailscale-up] skipped (boot phase)" /tmp/out; then
        echo "  ok  container dry-run worker --prepare"; pass=$((pass+1))
      else
        echo "  FAIL container dry-run worker --prepare"; tail -5 /tmp/out; fail=$((fail+1))
      fi
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
