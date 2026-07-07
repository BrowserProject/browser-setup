#!/usr/bin/env bash
#
# provision.sh - provision a node over SSH with one command.
#
#   ./provision.sh root@1.2.3.4 --role worker --tailscale-key tskey-auth-...
#   ./provision.sh root@1.2.3.4 --role worker --modules gpu-intel,deadssd
#   ./provision.sh root@1.2.3.4 --role db --secrets-file ./secrets.env
#   ./provision.sh root@1.2.3.4 --role worker --server 100.x.y.z   # new/other control plane
#   ./provision.sh root@1.2.3.4 --role control-plane --cluster-env ./cluster.env --manifests ./manifests
#   ./provision.sh root@1.2.3.4                # fully guided on the node
#
# What it does:
#   1. bundles setup/ (and, if given, a --manifests dir) and streams them to
#      /opt/node-setup on the target (tar over ssh; no rsync dependency)
#   2. assembles /etc/node-setup/secrets.env on the node (0600; the node deletes
#      it on completion) from --secrets-file / --secrets-stdin / --tailscale-key /
#      --k3s-token, whichever you pass
#   3. runs node-setup remotely (interactive TTY unless --yes)
#
# SECRETS: this repo is public and intentionally ships NO credentials. Provide
# them at run time. The worker/gateway roles need TS_AUTHKEY + K3S_TOKEN; the
# control-plane role additionally needs K3S_TOKEN + REGISTRY_* and its services
# manifest (pass --manifests <dir>). A convenient pattern when you keep secrets
# in an age-encrypted store elsewhere:
#
#   my-secret-tool show prod | ./provision.sh root@1.2.3.4 --role worker \
#     --secrets-stdin --tailscale-key tskey-auth-...
#
# Generate a tailscale auth key at https://login.tailscale.com/admin/settings/keys
# (keys expire; pass one per run, they are never stored here).
#
# If a step needs a reboot (e.g. gpu-intel), the node reboots and FINISHES ON
# ITS OWN via node-setup-resume.service. Check with: ssh <node> node-setup status
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REMOTE_DIR="/opt/node-setup"

die() { echo "provision: $*" >&2; exit 1; }

TARGET="${1:-}"
[[ -n "$TARGET" && "$TARGET" != --* ]] || die "usage: provision.sh user@host [--role R] [options]"
shift

ROLE="" MODULES="" TS_KEY="" K3S_TOKEN_ARG="" SERVER_IP="" SECRETS_FILE="" SECRETS_STDIN=0 MANIFESTS_DIR="" CLUSTER_ENV="" PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)          ROLE="$2"; shift ;;
    --modules)       MODULES="$2"; shift ;;
    --server)        SERVER_IP="$2"; shift ;;
    --tailscale-key) TS_KEY="$2"; shift ;;
    --k3s-token)     K3S_TOKEN_ARG="$2"; shift ;;
    --secrets-file)  SECRETS_FILE="$2"; shift ;;
    --secrets-stdin) SECRETS_STDIN=1 ;;
    --manifests)     MANIFESTS_DIR="$2"; shift ;;
    --cluster-env)   CLUSTER_ENV="$2"; shift ;;
    --yes|-y|--dry-run) PASSTHRU+=("$1") ;;
    --only|--skip)   PASSTHRU+=("$1" "$2"); shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# Read stdin secrets before any other stdin-consuming command runs.
STDIN_SECRETS=""
if [[ "$SECRETS_STDIN" == "1" ]]; then
  STDIN_SECRETS="$(cat)"
fi

SSH=(ssh -o ConnectTimeout=10 "$TARGET")

echo "==> checking SSH connectivity to $TARGET"
"${SSH[@]}" true || die "cannot reach $TARGET over SSH"

echo "==> shipping setup bundle to $TARGET:$REMOTE_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bundle"
cp -a "$HERE/setup" "$STAGE/bundle/setup"
# Ship the real per-cluster config (kept private, out of this repo). Without it
# node-setup falls back to setup/cluster.env.example.
if [[ -n "$CLUSTER_ENV" ]]; then
  [[ -f "$CLUSTER_ENV" ]] || die "--cluster-env file not found: $CLUSTER_ENV"
  cp -a "$CLUSTER_ENV" "$STAGE/bundle/setup/cluster.env"
fi
if [[ -n "$MANIFESTS_DIR" ]]; then
  [[ -d "$MANIFESTS_DIR" ]] || die "--manifests dir not found: $MANIFESTS_DIR"
  mkdir -p "$STAGE/bundle/manifests"
  cp -a "$MANIFESTS_DIR"/*.yaml "$STAGE/bundle/manifests/"
fi
tar -C "$STAGE/bundle" -czf - . | "${SSH[@]}" "mkdir -p $REMOTE_DIR && tar -C $REMOTE_DIR -xzf -"

# Assemble secrets.env on the node from whatever the caller supplied. Plaintext
# never touches disk on either side (pipe + 0600 target under umask). If nothing
# is supplied, node-setup prompts on the node for what each step needs.
if [[ -n "$SECRETS_FILE" || -n "$STDIN_SECRETS" || -n "$TS_KEY" || -n "$K3S_TOKEN_ARG" ]]; then
  echo "==> pushing secrets to $TARGET:/etc/node-setup/secrets.env"
  {
    [[ -n "$SECRETS_FILE" ]] && cat "$SECRETS_FILE"
    [[ -n "$STDIN_SECRETS" ]] && printf '%s\n' "$STDIN_SECRETS"
    [[ -n "$TS_KEY" ]] && printf 'TS_AUTHKEY=%s\n' "$TS_KEY"
    [[ -n "$K3S_TOKEN_ARG" ]] && printf 'K3S_TOKEN=%s\n' "$K3S_TOKEN_ARG"
    true
  } | "${SSH[@]}" "umask 077 && mkdir -p /etc/node-setup && cat > /etc/node-setup/secrets.env"
else
  echo "==> no secrets supplied; node-setup will prompt on the node for what it needs"
fi

CMD=("$REMOTE_DIR/setup/node-setup")
[[ -n "$ROLE" ]]      && CMD+=(--role "$ROLE")
[[ -n "$MODULES" ]]   && CMD+=(--modules "$MODULES")
[[ -n "$SERVER_IP" ]] && CMD+=(--server "$SERVER_IP")
CMD+=("${PASSTHRU[@]:-}")

echo "==> running: ${CMD[*]}"
set +e
ssh -t -o ConnectTimeout=10 "$TARGET" "chmod +x $REMOTE_DIR/setup/node-setup && ${CMD[*]}"
rc=$?
set -e

case "$rc" in
  0) echo "==> DONE. Verify any time with: ssh $TARGET node-setup doctor" ;;
  3) echo "==> REBOOT PENDING. The node continues on its own after the reboot."
     echo "    Watch:  ssh $TARGET node-setup status"
     echo "    Logs:   ssh $TARGET journalctl -u node-setup-resume -f" ;;
  *) die "remote node-setup failed (rc=$rc); re-run this command after fixing the cause - completed steps are skipped" ;;
esac
