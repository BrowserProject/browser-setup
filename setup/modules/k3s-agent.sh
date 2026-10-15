# k3s-agent.sh - join this node to the cluster as a k3s agent.
# shellcheck shell=bash

# get.k3s.io as fetched by an image bake; the join on a node booted from that
# image re-runs it without downloading the binary again.
K3S_INSTALLER_CACHE=/usr/local/lib/node-setup/k3s-install.sh

_k3s_installed_version() {
  k3s --version 2>/dev/null | head -n1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' || true
}

# The cached installer and the pinned binary are both in place.
_k3s_preinstalled() {
  [[ -s "$K3S_INSTALLER_CACHE" && "$(_k3s_installed_version)" == "$K3S_VERSION" ]]
}

_k3s_agent_joined() { # root ("" for this host) -> 0 when the agent runs or has registered
  systemctl is-active --quiet k3s-agent 2>/dev/null || [[ -e "$1/etc/rancher/node/password" ]]
}

STEP_DESC["k3s-agent-preinstall"]="image bake: pinned k3s binary and a disabled agent unit (k3s-agent-install joins at boot)"
STEP_PHASE["k3s-agent-preinstall"]=bake
k3s-agent-preinstall::check() {
  _k3s_preinstalled && systemctl cat k3s-agent.service >/dev/null 2>&1
}
k3s-agent-preinstall::apply() {
  # The installer disables the unit and rewrites its env file: on a joined
  # node that would drop the join on the next restart.
  if _k3s_agent_joined ""; then
    die "k3s-agent has joined a cluster on this host; the pre-install is for a fresh image bake only"
  fi
  mkdir -p "$(dirname "$K3S_INSTALLER_CACHE")"
  curl -fsSL --retry 5 --retry-delay 5 https://get.k3s.io -o "$K3S_INSTALLER_CACHE"
  # The installer writes every K3S_* variable it sees into the unit's env file,
  # which the image keeps.
  env -u K3S_TOKEN -u K3S_URL \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    INSTALL_K3S_SKIP_ENABLE=true \
    INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_EXEC="agent --flannel-iface=tailscale0" \
    sh "$K3S_INSTALLER_CACHE"
}
k3s-agent-preinstall::verify() {
  [[ "$(_k3s_installed_version)" == "$K3S_VERSION" ]] \
    && ! systemctl is-enabled --quiet k3s-agent \
    && ! grep -qs '^K3S_TOKEN=' /etc/systemd/system/k3s-agent.service.env
}

STEP_DESC["k3s-agent-install"]="install pinned k3s agent joined via the tailnet"
STEP_PHASE["k3s-agent-install"]=boot
k3s-agent-install::check() {
  systemctl is-active --quiet k3s-agent \
    && [[ "$(_k3s_installed_version)" == "$K3S_VERSION" ]]
}
k3s-agent-install::apply() {
  require_secrets K3S_TOKEN
  local ip
  ip="$(ts_ip)"
  [[ -n "$ip" ]] || die "no tailscale IP; tailscale-up must run first"

  # The control plane must be reachable over the tailnet before the installer
  # blocks on it; fail early with a useful message instead.
  retry 5 3 curl -ksfo /dev/null --max-time 5 "$K3S_URL/ping" \
    || die "control plane $K3S_URL not reachable over the tailnet"

  local exec_args=(agent "--node-ip=${ip}" "--flannel-iface=tailscale0")
  local label
  for label in "${K3S_NODE_LABELS[@]}"; do
    exec_args+=("--node-label=${label}")
  done

  local -x INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$K3S_TOKEN" K3S_URL="$K3S_URL" \
    INSTALL_K3S_EXEC="${exec_args[*]}"
  if _k3s_preinstalled; then
    INSTALL_K3S_SKIP_DOWNLOAD=true sh "$K3S_INSTALLER_CACHE"
  else
    curl -sfL https://get.k3s.io | sh -
  fi
}
k3s-agent-install::verify() {
  systemctl is-active --quiet k3s-agent || return 1
  # flannel.1 appearing means the node registered and the overlay attached.
  if ! wait_for 180 5 ip link show flannel.1 >/dev/null 2>&1; then
    err "k3s-agent is active but flannel.1 never appeared; check: journalctl -u k3s-agent"
    return 1
  fi
}
