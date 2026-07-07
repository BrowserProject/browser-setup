# role: gateway - k3s agent labeled type=gateway; serves public 80/443 via the
# proxy/edge daemonsets. Runs no Docker browser workspaces, so no Docker engine
# and no exit-node routing (deliberate deviation from the old PROD.md, which
# installed Docker on every node).
# shellcheck shell=bash

UFW_PUBLIC_TCP=("${GATEWAY_PUBLIC_TCP[@]}")
UFW_PUBLIC_UDP=("${GATEWAY_PUBLIC_UDP[@]}")
K3S_NODE_LABELS=("type=gateway")

ROLE_STEPS=(
  base-packages
  base-time
  base-journald
  base-unattended
  base-ssh-harden
  swap-disable
  tailscale-install
  tailscale-up
  ufw-rules
  k3s-agent-install
  flannel-watchdog
  oom-guards
  net-limits
  hw-watchdog
  disk-guard
)
