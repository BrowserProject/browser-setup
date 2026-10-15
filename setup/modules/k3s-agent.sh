# k3s-agent.sh - join this node to the cluster as a k3s agent.
# shellcheck shell=bash

_k3s_installed_version() {
  k3s --version 2>/dev/null | head -n1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' || true
}

STEP_DESC["k3s-agent-install"]="install pinned k3s agent joined via the tailnet"
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

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    K3S_TOKEN="$K3S_TOKEN" \
    K3S_URL="$K3S_URL" \
    INSTALL_K3S_EXEC="${exec_args[*]}" \
    sh -
}
k3s-agent-install::verify() {
  systemctl is-active --quiet k3s-agent || return 1
  # flannel.1 appearing means the node registered and the overlay attached.
  if ! wait_for 180 5 ip link show flannel.1 >/dev/null 2>&1; then
    err "k3s-agent is active but flannel.1 never appeared; check: journalctl -u k3s-agent"
    return 1
  fi
}
