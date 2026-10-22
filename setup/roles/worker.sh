# role: worker - k3s agent that runs browser workspaces via Docker.
# Optional extras (via --modules): deadssd, direct-egress, alt-tailscale-port,
# profile-share (premium workers), profile-share-server (beta-w1, with profile-share).
# shellcheck shell=bash

UFW_PUBLIC_TCP=("${WORKER_PUBLIC_TCP[@]}")
UFW_PUBLIC_UDP=("${WORKER_PUBLIC_UDP[@]}")
K3S_NODE_LABELS=("${WORKER_NODE_LABELS[@]}")

ROLE_STEPS=(
  base-packages
  base-time
  base-journald
  base-unattended
  base-ssh-harden
  base-services
  swap-disable
  session-limits
  tailscale-install
  tailscale-up
  docker-install
  docker-daemon-config
  ufw-rules
  session-isolation
  profile-legacy-cleanup
  k3s-agent-install
  flannel-watchdog
  oom-guards
  net-limits
  hw-watchdog
  disk-guard
)

# Workers route Docker traffic through a Mullvad exit node (prod).
if [[ "${EXITNODE_ROUTING:-0}" == "1" ]]; then
  ROLE_STEPS+=(exitnode-routing)
fi
