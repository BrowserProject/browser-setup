# role: worker - k3s agent that runs browser workspaces via Docker.
# Optional extras (via --modules): deadssd, direct-egress.
# Preparable: `node-setup --role worker --prepare` bakes a disk image; a normal
# run on a node booted from it applies only what the image lacks (the join).
# shellcheck shell=bash

UFW_PUBLIC_TCP=("${WORKER_PUBLIC_TCP[@]}")
UFW_PUBLIC_UDP=("${WORKER_PUBLIC_UDP[@]}")
K3S_NODE_LABELS=("${WORKER_NODE_LABELS[@]}")
ROLE_PREPARABLE=1

ROLE_STEPS=(
  base-packages
  base-time
  base-journald
  base-unattended
  base-ssh-harden
  swap-disable
  session-limits
  tailscale-install
  tailscale-up
  docker-install
  docker-daemon-config
  ufw-rules
  session-isolation
  k3s-agent-preinstall
  k3s-agent-install
  flannel-watchdog
  oom-guards
  net-limits
  hw-watchdog
  disk-guard
  browser-images-prefetch
)

# Workers route Docker traffic through a Mullvad exit node (prod).
if [[ "${EXITNODE_ROUTING:-0}" == "1" ]]; then
  ROLE_STEPS+=(exitnode-routing)
fi
