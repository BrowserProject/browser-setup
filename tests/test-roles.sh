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
# default from cluster.env when no override
SB="$(mktemp -d)"
DEFAULT_IP="$(sed -n 's/^K3S_SERVER_IP="\([0-9.]*\)"/\1/p' "$INFRA/setup/cluster.env")"
out="$(NODE_SETUP_STATE_DIR="$SB/state" NODE_SETUP_CONF_DIR="$SB/conf" NO_COLOR=1 \
      "$INFRA/setup/node-setup" --role worker --dry-run --yes 2>&1)"
if grep -q "control plane: $DEFAULT_IP" <<< "$out"; then
  ok "default control plane IP comes from cluster.env ($DEFAULT_IP)"
else
  fail "default control plane IP"; echo "$out" | tail -3
fi
rm -rf "$SB"

echo "== 3c. invalid inputs are rejected =="
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
